# quint-connect-hegel-ruby

Test a Ruby system against a [Quint](https://github.com/quint-co/quint) spec.
The spec says what each command must do, and the tests run the same commands on the real system and compare the two after every step.

There are two ways to choose the steps, and both use the same driver:

- **Trace replay.** `quint run --mbt` writes traces, and each trace runs on the system step by step. Quint picks the steps, so a trace reaches deep states quickly.
- **Hegel.** [Hegel](https://github.com/meganemura/hegel-ruby) picks each step from the actions the spec allows now. When the system disagrees with the spec, Hegel shrinks the failure to a short sequence of commands.

The spec is read from Quint's JSON IR and evaluated inside the Ruby process, so a Hegel step does not start another process.

## Installation

```ruby
# Gemfile
gem "quint_connect_hegel", github: "meganemura/quint-connect-hegel-ruby"
```

The gem needs Ruby 3.4 or later, as hegeltest 0.4 does.

The gem calls the `quint` command line. Set `QUINT` to the command to use, for example a local install. Without it, the gem runs `npx --yes @informalsystems/quint@0.33.0`, which needs Node.js.

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

Plain values: a Quint set is a `Set`, a map a `Hash`, a tuple an `Array`, a record a `Hash` with string keys, and a sum type its tag, or `[tag, value]` when it carries a value.

[examples/loans](examples/loans) has the whole example: the spec, the system, and the driver.

## Run it

```ruby
spec = QuintConnectHegel::Spec.new("loans.qnt", main: "loans")

# Trace replay: Quint picks the steps.
QuintConnectHegel::Quint.simulate("loans.qnt", traces: 50, max_steps: 20, seed: "1") do |path|
  QuintConnectHegel::Trace.replay(path, LoansDriver.new)
end

# Hegel picks the steps and shrinks a failure.
machine = QuintConnectHegel.machine(spec, driver: -> { LoansDriver.new }, invariants: %i[one_book_each])
Hegel.test(test_cases: 100) { |tc| Hegel::Stateful.run(machine.new, tc) }
```

Both raise `QuintConnectHegel::Mismatch` with each variable that differs. The code runs the same in a Minitest test and in an RSpec example. In RSpec, include `Hegel::Syntax::Methods` if your own examples draw values; the machine itself does not need it.

`QuintConnectHegel.machine` takes these options:

- `step:` is the action that lists the moves, `"step"` by default. Each move must call a named action. Arguments come from `nondet x = S.oneOf()`.
- `invariants:` names `val`s of the spec that must hold after every move.
- `choose:` is how Hegel draws a move. `:rule` (the default) picks an action and rejects it when the spec disables it. It shrinks to the shortest sequence. `:rotate` passes a disabled action's turn to the next enabled one. It reaches deep states with fewer test cases, but a shrunk sequence can keep extra moves.

Each test case starts a new system through the driver's `init`. A sequence of moves that the system already agreed on is not run again, because shrinking asks for the same sequence many times. This assumes that the system answers the same sequence the same way each time. A disagreement always runs on the system again.

## Check the Ruby model

The Hegel way trusts the Ruby evaluation of the spec. The model answers the driver protocol, so you can hold it to Quint's own traces:

```ruby
QuintConnectHegel::Quint.simulate("loans.qnt", traces: 200, max_steps: 30, seed: "7") do |path|
  QuintConnectHegel::Trace.replay(path, spec.model)
end
```

The model evaluates the operators a command-per-action spec uses: sets, maps, records, tuples, sum types with `match`, integers, and booleans. Any other operator raises `QuintConnectHegel::Model::Unsupported`, so a spec that needs more fails loudly.

## Development

```sh
bundle install
bundle exec bin/test    # Minitest
bundle exec rspec       # RSpec
```

The tests run `quint`. Set `QUINT` to skip `npx`.

## License

MIT

[Japanese](README.ja.md)
