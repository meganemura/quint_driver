# quint_driver

Test a Ruby system against a [Quint](https://github.com/quint-co/quint) spec.
The spec says what each command must do, and the tests run the same commands on the real system and compare the two after every step.

There are two ways to choose the steps, and both use the same driver:

- **Trace replay.** `quint run --mbt` writes traces, and each trace runs on the system step by step. Quint picks the steps, so a trace reaches deep states quickly.
- **Hegel.** [Hegel](https://github.com/meganemura/hegel-ruby) picks each step from the actions the spec allows now. When the system disagrees with the spec, Hegel shrinks the failure to a short sequence of commands.

The spec is read from Quint's JSON IR and evaluated inside the Ruby process, so a Hegel step does not start another process.

## Installation

```ruby
# Gemfile
gem "quint_driver", github: "meganemura/quint_driver"
gem "hegeltest", "= 0.4.1" # only for the Hegel adapter
```

Trace replay and the model load with `require "quint_driver"`. They need Ruby 3.3 or later and no other gem.

The Hegel adapter loads with `require "quint_driver/hegel"`. It needs hegeltest 0.4.1, which needs Ruby 3.4 or later. The gem does not depend on hegeltest, so add it to your own Gemfile.

The gem calls the `quint` command line. Set `QUINT` to the command to use, for example a local install. Without it, the gem runs `npx --yes @informalsystems/quint@0.33.0`, which needs Node.js and, the first time, the npm registry. When npx cannot fetch quint, for example offline, the gem raises `QuintDriver::QuintFailed` that says so and asks you to set `QUINT`.

`Spec.new` compiles a file once per process and quint command, and compiles it again when the file's text changes. Every module of the file shares that compile, so a `Spec.new` or `Quint.simulate` for another `main:` of the same file starts no node. A change to a file the spec imports is not seen until the process starts again.

`Quint.simulate` runs Quint's Rust evaluator directly, without node, when it finds one: the copy quint downloaded into `QUINT_HOME/rust-evaluator-v0.7.0/` (`~/.quint` when `QUINT_HOME` is unset). Set `QUINT_EVALUATOR` to the evaluator to use another copy, or to an empty string to run `quint run` instead. The same seed gives the same traces on both ways. The gem reads only the input and output format of evaluator v0.7.0, the one quint 0.33.0 runs; an evaluator that answers in another format raises `QuintDriver::QuintFailed`. Without an evaluator, or with a `step:` that names no action of the module, `Quint.simulate` runs `quint run`.

### The agent skill

The [quint_driver skill](skills/quint_driver/SKILL.md) takes a coding agent through the spec shape, the driver, trace replay, the model check, and Hegel. Install it with the [`skills`](https://github.com/vercel-labs/skills) CLI (Node.js 22.20 or later). This repository is private, so these commands need GitHub access.

```sh
npx skills add meganemura/quint_driver
```

```sh
npx skills add meganemura/quint_driver --skill quint_driver
```

```sh
npx skills add meganemura/quint_driver -g
```

```sh
npx skills add meganemura/quint_driver -a claude-code
```

`--skill` selects this skill, `-g` installs it for every project, and `-a` targets one agent. Add `-y` to skip prompts.

To copy or symlink it instead:

```sh
mkdir -p .agents/skills
ln -s /path/to/quint_driver/skills/quint_driver .agents/skills/quint_driver
```

`.claude/skills/` and `.cursor/skills/` work the same way.

## Write a driver

A driver runs the spec's actions on your system and reads the system back in the spec's terms.

```ruby
class LoansDriver
  # Runs one action of the spec. "init" comes first in every sequence.
  # +picks+ holds the nondet values, such as { "m" => "m1", "b" => "b2" }.
  def step(action, picks)
    @outcome = "Done"
    case action.delete_suffix("_refused")
    when "init" then @loans = Loans.new
    when "borrow" then @loans.borrow(picks.fetch("m"), picks.fetch("b"))
    when "give_back" then @loans.give_back(picks.fetch("b"))
    end
  rescue Loans::Refused => refusal
    @outcome = [ "Refused", refusal.reason.to_s ]
  end

  # The spec's variables as plain Ruby values. Only the variables returned here are compared.
  def state
    { "holder" => %w[b1 b2 b3].to_h { [ _1, @loans.holder(_1) || "" ] }, "outcome" => @outcome }
  end
end
```

Plain values: a Quint set is a `Set`, a map a `Hash`, a tuple or a list an `Array`, a record a `Hash` with string keys, and a sum type its tag, or `[tag, value]` when it carries a value.

[examples/loans](examples/loans) has the whole example: the spec, the system, and the driver.

## Run it

```ruby
require "quint_driver"

spec = QuintDriver::Spec.new("loans.qnt", main: "loans")

# Trace replay: Quint picks the steps.
QuintDriver::Quint.simulate("loans.qnt", traces: 50, max_steps: 20, seed: "1") do |path|
  QuintDriver::Trace.replay(path, LoansDriver.new)
end

# Hegel picks the steps and shrinks a failure.
require "quint_driver/hegel"
machine = QuintDriver.machine(spec, driver: -> { LoansDriver.new }, invariants: %i[one_book_each])
Hegel.test(test_cases: 100) { |tc| Hegel::Stateful.run(machine.new, tc) }
```

Both raise `QuintDriver::Mismatch` with each variable that differs and the steps the driver ran from `init`, so you can run the failure again by hand. Each value prints with a set's elements and a hash's keys sorted, so the spec's side and the driver's side print a record in one key order. The message ends with a `trace:` line. After `Quint.simulate` returns, the file it replayed is gone, so the line names the trace by its file name and the call that writes the same trace again, such as `trace: trace_0.itf.json of Quint.simulate("loans.qnt", traces: 50, max_steps: 20, seed: "1", step: "step", backend: "rust")`. The error reads the same inside the block, and holds those facts as `trace`, `seed`, and `simulate`. A `Mismatch` your own code raises inside the block, such as from a check of your own after the replay, gets the same `trace:` line when it leaves the block. A replay of a trace file of your own names its path. To watch a replay, pass `log: $stdout` to `Trace.replay`; it prints each step, such as `step 1 borrow {"b" => "b1", "m" => "m2"}`, before the driver runs it. The code runs the same in a Minitest test and in an RSpec example. In RSpec, include `Hegel::Syntax::Methods` if your own examples draw values; the machine itself does not need it.

`Quint.simulate` runs the module named after the file. Pass `main:` to run another module of that file, the same name `Spec.new` takes. When quint fails or is not installed, `Spec.new` and `Quint.simulate` raise `QuintDriver::QuintFailed` with quint's reason.

`QuintDriver.machine` takes these options:

- `step:` is the action that lists the moves, `"step"` by default. Each move must call a named action. Arguments come from `nondet x = S.oneOf()`.
- `invariants:` names `val`s of the spec that must hold after every move.
- `choose:` is how Hegel draws a move. `:rule` (the default) picks an action and rejects it when the spec disables it. It shrinks to the shortest sequence. `:rotate` passes a disabled action's turn to the next enabled one. It reaches deep states with fewer test cases, but a shrunk sequence can keep extra moves. Hegel's failure report names each draw after the nondet pick it chose, numbered per move (`m_1 = "m2"`), or `rule_1` and `move_1` under `:rotate`.

Each test case starts a new system through the driver's `init`. A sequence of moves that the system already agreed on is not run again, because shrinking asks for the same sequence many times. This assumes that the system answers the same sequence the same way each time. A disagreement always runs on the system again.

## Check the Ruby model

The Hegel way trusts the Ruby evaluation of the spec. The model answers the driver protocol, so you can hold it to Quint's own traces:

```ruby
QuintDriver::Quint.simulate("loans.qnt", traces: 200, max_steps: 30, seed: "7") do |path|
  QuintDriver::Trace.replay(path, spec.model)
end
```

The model evaluates the operators a command-per-action spec uses: sets (with `fold` and `i.to(j)`), maps, records, tuples, lists, sum types with `match`, integers, and booleans. A list is a Ruby Array, and the model evaluates `List`, `append`, `concat`, `head`, `tail`, `length`, `nth`, `indices`, `replaceAt`, `slice`, `range`, `select`, `foldl`, and `foldr`. Quint's builtin docs leave `foldr` out, but both of its evaluators fold from the right and pass the element first, `(x, acc) => ...`, and the model does the same. On integers it evaluates `+`, `-`, `*`, unary `-`, and the comparisons, and `/` and `%` only on non-negative operands, because Quint documents no rounding for a negative one. Both of Quint's evaluators truncate toward zero (`-7 % 2` is `-1`), and Ruby floors (`-7 % 2` is `1`), so the model refuses a negative operand rather than answer differently. Where Quint's docs leave an operation undefined, such as `head` of an empty list or `nth` past the end, the model raises `QuintDriver::Unsupported` instead of picking an answer; `slice(l, l.length(), l.length())` is `[]`, as both of Quint's evaluators give it. Any other operator, such as `powerset`, raises `QuintDriver::Unsupported`, so a spec that needs more fails loudly. So does a step arm that names no action, and its message names the action that holds the arm, such as `quint: counting assigns n' in an arm that names no action; name every action in step` when `step` opens `counting` in place. The message names the action or definition that holds the operator, such as `quint: no evaluation for operator powerset in subsets`. For an operator in a nondet domain, that is the action that draws it, which can be an action that `step` opens in place.

`Spec#model` is the one way to build a model; `Model.new` is private, because the model trusts the shape of quint's compiled IR. A trace gives each pick as a plain value, and the model takes the value of the pick's domain that reads the same, so a pick of a sum type works in `match`.

`model.moves(rule)` lists every move a rule of `spec.rules("step")` allows in the model's current state, as `[action, picks, next state]` in a fixed order. `model.enter(next_state)` takes one. The Hegel machine draws its moves this way. `model.value(node, env)` evaluates one IR node, or the definition a string names, in the current state. Pass `within: rule.within` when the node is a domain or an argument of a rule, so a refusal names that action; without it, the message says the node is `outside any definition`.

## Development

```sh
bundle install
bundle exec bin/test    # Minitest
bundle exec rspec       # RSpec
```

The Hegel tests are under `test/hegel/` and `spec/hegel/`. On Ruby 3.3, leave out hegeltest and run the rest:

```sh
BUNDLE_WITHOUT=hegel bundle install
BUNDLE_WITHOUT=hegel bundle exec bin/test test/*_test.rb
BUNDLE_WITHOUT=hegel bundle exec rspec --exclude-pattern "spec/hegel/**/*_spec.rb"
```

The tests run `quint`. Set `QUINT` to skip `npx`.

## License

MIT

[Japanese](README.ja.md)
