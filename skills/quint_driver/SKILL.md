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
- `state` returns only the variables to compare, as plain values: a set is a `Set`, a map a `Hash`, a tuple an `Array`, a record a `Hash` with string keys, and a sum type its tag, or `[tag, value]` when it carries one.

## 3. Replay Quint's traces

```ruby
require "quint_driver"

QuintDriver::Quint.simulate("spec.qnt", main: "loans", traces: 50, max_steps: 20, seed: "1") do |path|
  QuintDriver::Trace.replay(path, LoansDriver.new)
end
```

Quint chooses the steps, so replay reaches deep states quickly. It works the same in a Minitest test and in an RSpec example.

## 4. Check the Ruby model

Hegel trusts the Ruby evaluation of the spec. Hold the model to Quint's own traces first:

```ruby
spec = QuintDriver::Spec.new("spec.qnt", main: "loans")
QuintDriver::Quint.simulate("spec.qnt", main: "loans", traces: 200, max_steps: 30, seed: "7") do |path|
  QuintDriver::Trace.replay(path, spec.model)
end
```

An operator the model does not evaluate raises `QuintDriver::Unsupported`. Go on to step 5 only when this passes.

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
quint: after step 9 `borrow_refused` {"b" => "b1", "m" => "m2"} of /tmp/quint20261103-16417-qykl1y/trace_0.itf.json, the driver differs from the trace
  holder: trace {"b1" => "", "b2" => "m1", "b3" => "m2"}, driver {"b1" => "m2", "b2" => "m1", "b3" => "m2"}
  outcome: trace ["Refused", "limit_reached"], driver "Done"
steps:
  init {}
  give_back_refused {"b" => "b1"}
  give_back_refused {"b" => "b3"}
  borrow {"b" => "b3", "m" => "m2"}
  give_back_refused {"b" => "b1"}
  give_back_refused {"b" => "b2"}
  borrow {"b" => "b2", "m" => "m1"}
  borrow_refused {"b" => "b2", "m" => "m1"}
  borrow_refused {"b" => "b3", "m" => "m1"}
  borrow_refused {"b" => "b1", "m" => "m2"}
Quint.simulate("spec.qnt", traces: 50, max_steps: 20, seed: "1", main: "loans", step: "step", backend: "rust") wrote this trace as trace_0.itf.json
```

- Each line before `steps:` names one variable that differs. `trace`, or `model` under Hegel, is what the spec says. `driver` is what the system did.
- `steps:` lists every step from `init`. Run them on a new driver to reproduce the failure.
- The trace file is gone after `simulate` returns. The last line is the call that writes the same trace again.
- Under Hegel, `steps:` is the shrunk sequence.

| Error | Cause |
| --- | --- |
| `QuintDriver::Mismatch` | The system and the spec disagree. |
| `QuintDriver::Unsupported` | The spec uses an operator the model does not evaluate, or a move names no action of `step`. |
| `QuintDriver::QuintFailed` | quint rejected the spec, or the `QUINT` command is not installed. |
