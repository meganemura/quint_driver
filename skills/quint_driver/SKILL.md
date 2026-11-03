---
name: quint_driver
description: Use when testing a Ruby system against a Quint spec with the quint_driver gem. Shape the spec so every move names an action, write a driver, replay Quint's traces, check the Ruby model, then let Hegel choose and shrink the steps.
---

# quint_driver

quint_driver runs a Ruby system the way a Quint spec says and compares the two after every step. You write the spec and a driver. Quint or Hegel chooses the steps. A disagreement raises `QuintDriver::Mismatch` with the steps that reproduce it.

## Install

```sh
npm install --global @informalsystems/quint@0.33.0
export QUINT=quint
```

```ruby
# Gemfile
gem "quint_driver", github: "meganemura/quint_driver"
gem "hegeltest", "= 0.4.1" # only for step 5
```

Steps 1 to 4 need Ruby 3.3 or later and no other gem. Step 5 needs hegeltest, which needs Ruby 3.4 or later. Without `QUINT`, the gem runs `npx --yes @informalsystems/quint@0.33.0`. The gem reads `QUINT` each time it runs quint.

The first `quint run` downloads the Rust evaluator into `~/.quint/rust-evaluator-v0.7.0/`. When the network blocks api.github.com, download it from the release instead. Pick the target of your machine, such as `x86_64-unknown-linux-gnu` or `aarch64-apple-darwin`:

```sh
mkdir -p ~/.quint/rust-evaluator-v0.7.0
curl -sSL https://github.com/quint-co/quint/releases/download/evaluator/v0.7.0/quint_evaluator-x86_64-unknown-linux-gnu.tar.gz \
  | tar xz -C ~/.quint/rust-evaluator-v0.7.0
```

With that evaluator in place, `Quint.simulate` runs it directly and skips node; the same seed gives the same traces as `quint run`. Set `QUINT_EVALUATOR` to another copy of evaluator v0.7.0, or to an empty string to go through `quint run`.

## 1. Shape the spec

Each move of `step` must name the action that a driver runs.

- Write `step` as `any { ... }` whose arms call named actions, even for one action: `action step = any { tick }`. Without `any`, Quint names every move `step`, so a driver cannot tell the moves apart, and replay through the model raises `QuintDriver::Unsupported`.
- Take arguments only from `nondet x = S.oneOf()` before the call: `nondet b = BOOKS.oneOf() any { give_back(b), give_back_refused(b) }`.
- A parameterless action whose body is `any { ... }` opens in place, so `action step = any { lending, returning }` works.
- Do not assign inline in an arm of `step` (`any { n' = n + 1 }`). The move names no action, and quint_driver raises `QuintDriver::Unsupported`.
- Give each command a refused twin that holds when the command is disabled and records why, such as `borrow_refused`. Traces then check refusals too.
- Assign every variable in `init` and in every action.

```sh
quint typecheck spec.qnt
```

When the file holds several modules, pass the module name as `main:` to `Spec.new` and to `Quint.simulate`.

## 2. Write the driver

```ruby
class LoansDriver
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

  def state
    { "holder" => %w[b1 b2 b3].to_h { [ _1, @loans.holder(_1) || "" ] }, "outcome" => @outcome }
  end
end
```

- `step("init", {})` comes first in every sequence. Make a new system there.
- `picks` holds the nondet values by name.
- A refused twin runs the same command. Rescue the domain error into the spec's refusal value.
- `state` returns only the variables to compare, as plain values: a set is a `Set`, a map a `Hash`, a tuple or a list an `Array`, a record a `Hash` with string keys, and a sum type its tag, or `[tag, value]` when it carries one.

## 3. Replay Quint's traces

```ruby
require "quint_driver"

QuintDriver::Quint.simulate("spec.qnt", main: "loans", traces: 50, max_steps: 20, seed: "1") do |path|
  QuintDriver::Trace.replay(path, LoansDriver.new)
end
```

Quint chooses the steps, so replay reaches deep states quickly. It works the same in a Minitest test and in an RSpec example. Pass `log: $stdout` to `Trace.replay` to print each step before the driver runs it.

## 4. Check the Ruby model

Hegel trusts the Ruby evaluation of the spec. Hold the model to Quint's own traces first:

```ruby
spec = QuintDriver::Spec.new("spec.qnt", main: "loans")
QuintDriver::Quint.simulate("spec.qnt", main: "loans", traces: 200, max_steps: 30, seed: "7") do |path|
  QuintDriver::Trace.replay(path, spec.model)
end
```

`spec.model` is the one way to build a model. It evaluates sets, maps, records, tuples, lists (`append`, `concat`, `head`, `tail`, `length`, `nth`, `indices`, `replaceAt`, `slice`, `range`, `select`, `foldl`), sum types, integers (`/` only on non-negative operands), and booleans. An operation Quint's docs leave undefined, such as `head` of an empty list, raises `QuintDriver::Unsupported` too. An operator the model does not evaluate raises `QuintDriver::Unsupported`, and the message names the action or definition that holds it, such as `quint: no evaluation for operator foldr in summed`. Go on to step 5 only when this passes. `model.moves(rule)` lists the `[action, picks, next state]` moves a rule of `spec.rules("step")` allows now, and `model.enter(next_state)` takes one. `model.value(node, env, within: rule.within)` evaluates one IR node of a rule; without `within:`, a refusal says the node is `outside any definition`.

## 5. Let Hegel choose and shrink

```ruby
require "quint_driver/hegel"

machine = QuintDriver.machine(spec, driver: -> { LoansDriver.new }, invariants: %i[one_book_each])
Hegel.test(test_cases: 100, seed: 1, suppress_health_check: %i[filter_too_much too_slow]) do |tc|
  Hegel::Stateful.run(machine.new, tc)
end
```

- `invariants:` names `val`s of the spec that must hold after every move.
- `choose: :rotate` gives a disabled action's turn to the next enabled one. Use it when most actions are disabled in most states. The default, `:rule`, shrinks to the shortest sequence.
- `Hegel::Stateful.run(machine.new, tc, step_count: 50)` sets the most moves in one test case.

## Read a failure

```text
quint: after step 4 `borrow_refused` {"b" => "b3", "m" => "m2"}, the driver differs from the trace
  holder: trace {"b1" => "", "b2" => "m2", "b3" => ""}, driver {"b1" => "", "b2" => "m2", "b3" => "m2"}
  outcome: trace ["Refused", "limit_reached"], driver "Done"
steps:
  init {}
  borrow {"b" => "b2", "m" => "m2"}
  give_back {"b" => "b2"}
  borrow {"b" => "b2", "m" => "m2"}
  borrow_refused {"b" => "b3", "m" => "m2"}
trace: trace_0.itf.json of Quint.simulate("spec.qnt", traces: 50, max_steps: 20, seed: "1", main: "loans", step: "step", backend: "rust")
```

- Each line before `steps:` names one variable that differs. `trace`, or `model` under Hegel, is what the spec says. `driver` is what the system did.
- `steps:` lists every step from `init`. Run them on a new driver to reproduce the failure.
- `trace:` names the trace. Under `simulate`, the file is gone after `simulate` returns, so the line gives its file name and the call that writes the same trace again; outside `simulate`, it gives the path. A `Mismatch` reads the same whether you rescue it inside the `simulate` block or after it, and carries the same facts as `trace`, `seed`, and `simulate`. A `Mismatch` your own code raises inside the block gets the `trace:` line when it leaves the block, so raise `QuintDriver::Mismatch` from a check of your own too.
- Under Hegel, `steps:` is the shrunk sequence.

| Error | Cause |
| --- | --- |
| `QuintDriver::Mismatch` | The system and the spec disagree, or the model cannot take a move a trace took, such as a pick its domain does not hold. |
| `QuintDriver::Unsupported` | The spec uses an operator the model does not evaluate, a move names no action of `step`, or a move lacks a pick its action needs. |
| `QuintDriver::QuintFailed` | quint rejected the spec, `main:` names no module of the file (the message lists the modules it has), the `QUINT` command is not installed, `QUINT` is unset and npx could not fetch quint, or the `QUINT_EVALUATOR` evaluator cannot run or answers in a format other than v0.7.0's. |
