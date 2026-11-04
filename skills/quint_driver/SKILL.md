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
- Do not assign inline in an arm of `step` (`any { n' = n + 1 }`). The move names no action, and `spec.rules` raises `QuintDriver::Unsupported` with the action that holds the arm: `quint: counting assigns n' in an arm that names no action; name every action in step`.
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
- `picks` holds the nondet values by name. A pick the move did not make (Quint's `None`) is absent, so read one an action may go without as `picks["b"]`, which is `nil` then, and one it needs as `picks.fetch("b")`.
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

`Trace.replay` returns the steps it ran (`action`, `picks`, `expected`, `index`), so you can see what the traces reached before you trust a pass:

```ruby
reached = Hash.new(0)
QuintDriver::Quint.simulate("spec.qnt", main: "loans", traces: 50, max_steps: 20, seed: "1") do |path|
  QuintDriver::Trace.replay(path, LoansDriver.new).each { reached[_1.action] += 1 }
end
reached.sort.to_h # => {"borrow" => 214, "borrow_refused" => 283, "give_back" => 161, "give_back_refused" => 342, "init" => 50}
```

An action that never appears is one no test reached; raise `traces` or `max_steps`, or aim at it with `reach:`.

To test the steps that lead to one state, write a definition that holds there and pass its name as `reach:`. Each trace then ends at the first state where it holds, and only the traces that get there are yielded:

```ruby
# In loans.qnt: val two_on_loan = BOOKS.filter(b => onLoan(holder, b)).size() == 2
QuintDriver::Quint.simulate("spec.qnt", main: "loans", traces: 20, max_steps: 10, seed: "1", reach: "two_on_loan") do |path|
  QuintDriver::Trace.replay(path, LoansDriver.new)
end
```

One of those traces runs `init give_back_refused borrow borrow`. When no trace gets there, `Quint.simulate` raises `QuintDriver::QuintFailed`: `quint: no trace of 20 reached two_on_loan within 1 steps; raise max_steps or traces`. Raise `max_steps` or `traces` then.

To replay a named run (`run lendTest = init.then(...)`), use `Quint.test`. quint test writes no `mbt::actionTaken`, so the spec must record each step's action in a variable, as a sum type whose tag names the action and whose record holds its picks, the way a Choreo spec records it. Pass that variable's path as `action:`, and the path to the state the driver answers for as `state:`:

```ruby
QuintDriver::Quint.test("test/recorded.qnt", "lendTest", seed: "1") do |trace|
  QuintDriver::Trace.replay(trace, RecordedDriver.new, state: %w[s books], action: %w[s taken])
end
```

`test/recorded.qnt` in this repository, driven by `RecordedDriver` in `test/trace_test.rb`, keeps `var s: { books: str -> str, taken: Taken }` with `type Taken = Init | Borrow({ m: str, b: str }) | GiveBack({ b: str })`, so the driver gets `step("Init", {})`, then `step("Borrow", { "m" => "m1", "b" => "b1" })`, and its `state` returns the `books` map. A system that keeps a book's holder after `GiveBack` fails like this:

```
quint: after step 3 `GiveBack` {"b" => "b1"}, the driver differs from the trace
  b1: trace "", driver "m1"
steps:
  Init {}
  Borrow {"b" => "b1", "m" => "m1"}
  Borrow {"b" => "b2", "m" => "m2"}
  GiveBack {"b" => "b1"}
trace: test_0.itf.json of Quint.test("test/recorded.qnt", "lendTest", seed: "1")
```

Without `action:`, the replay raises `QuintDriver::Unsupported`: `quint: state 0 of the trace names no action taken; quint test writes no mbt::actionTaken, so pass action: the path to a variable that records it`.

A `state:` path that ends at a value that is no record or map raises `QuintDriver::Unsupported` before the driver runs, since the driver's `state` answers a record or map: `quint: state 0 of the trace has s.taken = "Init", which is no record or map; pass state: the path to the record or map the driver reports`.

## 4. Check the Ruby model

Hegel trusts the Ruby evaluation of the spec. Hold the model to Quint's own traces first. A module that imports, such as a test module that imports the spec's actions, reads what it imports as its own:

```ruby
spec = QuintDriver::Spec.new("spec.qnt", main: "loans")
QuintDriver::Quint.simulate("spec.qnt", main: "loans", traces: 200, max_steps: 30, seed: "7") do |path|
  QuintDriver::Trace.replay(path, spec.model)
end
```

`spec.model` is the one way to build a model. It evaluates sets, maps (`Map`, `get`, `keys`, `put`, `mapBy`, `set`, `setBy`, `setToMap`), records, tuples, lists (`append`, `concat`, `head`, `tail`, `length`, `nth`, `indices`, `replaceAt`, `slice`, `range`, `select`, `foldl`, and `foldr`, which Quint's docs leave out but both evaluators define as `(x, acc) => ...` from the right), sum types, integers (`/` and `%` only on non-negative operands, because Quint's evaluators truncate and Ruby floors), and booleans. An operation Quint's docs leave undefined, such as `head` of an empty list, raises `QuintDriver::Unsupported` too, and so does `get`, `set`, or `setBy` at a key the map does not have. An operator the model does not evaluate raises `QuintDriver::Unsupported`, and the message names the action or definition that holds it, such as `quint: no evaluation for operator powerset in subsets`. Go on to step 5 only when this passes. `model.moves(rule)` lists the `[action, picks, next state]` moves a rule of `spec.rules("step")` allows now, and `model.enter(next_state)` takes one. `model.value(node, env)` evaluates one IR node of a rule, and a refusal names the action the node is written in; for a node no definition holds, it says the node is `outside any definition`.

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

## In a Rails app with RSpec

A driver can call the app's service objects in place of the system's methods, and read the records back for `state`. The run below needs no Rails gem: `Loan` stands in for an ActiveRecord model, with the model methods that the services call. In an app, `Loan` is the model itself, and the Gemfile lines of Install go in the `:test` group.

```ruby
# app/models/loan.rb: stands in for an ActiveRecord model, one row per book on loan.
class Loan
  attr_reader :member, :book

  def self.all = (@rows ||= [])
  def self.delete_all = all.clear
  def self.create!(member:, book:) = new(member, book).tap { all << _1 }
  def self.find_by(book:) = all.find { _1.book == book }
  def self.exists?(**attributes) = all.any? { |row| attributes.all? { row.public_send(_1) == _2 } }

  def initialize(member, book) = (@member, @book = member, book)
  def destroy! = Loan.all.delete(self)
end
```

```ruby
# app/services/lending.rb: service objects a controller calls. A refusal is a domain error with a reason.
module Lending
  class Refused < StandardError
    attr_reader :reason

    def initialize(reason) = super(@reason = reason)
  end

  class BorrowBook
    def self.call(member:, book:)
      raise Refused, "on_loan" if Loan.exists?(book:)
      raise Refused, "limit_reached" if Loan.exists?(member:)

      Loan.create!(member:, book:)
    end
  end

  class GiveBack
    def self.call(book:)
      loan = Loan.find_by(book:) or raise Refused, "not_on_loan"
      loan.destroy!
    end
  end
end
```

The driver empties the table at `init`. One example replays many traces, and with transactional fixtures they all run in one transaction, so a trace does not start from an empty table by itself. The driver rescues the domain refusal into the spec's refusal value:

```ruby
# spec/quint/lending_driver.rb
class LendingDriver
  BOOKS = %w[b1 b2 b3].freeze

  def step(action, picks)
    @outcome = "Done"
    case action.delete_suffix("_refused")
    when "init" then Loan.delete_all
    when "borrow" then Lending::BorrowBook.call(member: picks.fetch("m"), book: picks.fetch("b"))
    when "give_back" then Lending::GiveBack.call(book: picks.fetch("b"))
    end
  rescue Lending::Refused => refusal
    @outcome = [ "Refused", refusal.reason ]
  end

  def state
    { "holder" => BOOKS.to_h { [ _1, Loan.find_by(book: _1)&.member || "" ] }, "outcome" => @outcome }
  end
end
```

The spec is `examples/loans/loans.qnt` of this repository, copied to `spec/quint/loans.qnt`. The spec path is relative, because RSpec runs from the app's root:

```ruby
# spec/quint/lending_spec.rb
require "quint_driver"
require "quint_driver/hegel"
require_relative "../../app/models/loan"
require_relative "../../app/services/lending"
require_relative "lending_driver"

RSpec.describe "lending, held to loans.qnt" do
  spec_file = "spec/quint/loans.qnt"

  it "follows every trace Quint writes" do
    QuintDriver::Quint.simulate(spec_file, main: "loans", traces: 50, max_steps: 20, seed: "1") do |path|
      QuintDriver::Trace.replay(path, LendingDriver.new)
    end
  end

  it "agrees with the model on every sequence Hegel chooses" do
    spec = QuintDriver::Spec.new(spec_file, main: "loans")
    machine = QuintDriver.machine(spec, driver: -> { LendingDriver.new }, invariants: %i[one_book_each])

    Hegel.test(test_cases: 100, seed: 1, suppress_health_check: %i[filter_too_much too_slow]) do |tc|
      Hegel::Stateful.run(machine.new, tc)
    end
  end
end
```

```text
$ bundle exec rspec spec/quint
..

Finished in 6.02 seconds (files took 0.18241 seconds to load)
2 examples, 0 failures
```

Without the `rescue`, the refusal leaves the driver. The replay fails with a `StepRaised`, and its `raised in:` line names the line of the service that refused:

```text
  1) lending, held to loans.qnt follows every trace Quint writes
     Failure/Error: raise Refused, "limit_reached" if Loan.exists?(member:)

     QuintDriver::StepRaised:
       quint: at step 4 `borrow_refused` {"b" => "b3", "m" => "m2"}, the step raised Lending::Refused: limit_reached
       raised in: app/services/lending.rb:12:in 'Lending::BorrowBook.call'
       steps:
         init {}
         borrow {"b" => "b2", "m" => "m2"}
         give_back {"b" => "b2"}
         borrow {"b" => "b2", "m" => "m2"}
         borrow_refused {"b" => "b3", "m" => "m2"}
       trace: trace_0.itf.json of Quint.simulate("spec/quint/loans.qnt", traces: 50, max_steps: 20, seed: "1", main: "loans", step: "step", backend: "rust")
     # ./app/services/lending.rb:12:in 'Lending::BorrowBook.call'
```

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
- Every value prints with a set's elements and a hash's keys sorted, so the two sides of a line, a replay and the machine, and Ruby 3.3 and 3.4 print the same value the same way.
- `trace:` names the trace. Under `simulate` or `test`, the file is gone after the call returns, so the line gives its file name and the call that writes the same trace again; outside `simulate`, it gives the path. A `Mismatch` reads the same whether you rescue it inside the `simulate` block or after it, and carries the same facts as `trace`, `seed`, and `written_by`. A `Mismatch` your own code raises inside the block gets the `trace:` line when it leaves the block, so raise `QuintDriver::Mismatch` from a check of your own too. Give it the message alone (`raise QuintDriver::Mismatch, "quint: the ledger lost a loan"`); `Mismatch.new` takes no `trace:`, `seed:`, or `written_by:`, because the gem fills them with the trace that ran.
- An error a step raises, in the driver's own code or in the system beneath it, is a `QuintDriver::StepRaised`, not a `Mismatch`: the two sides were never compared. Fix the code the message points at first. A domain error the driver lets through, such as `Loans::Refused` on a `_refused` step, lands here too; rescue it into the spec's refusal value, as step 2 does. The first line names the step and the error. The `raised in:` line names the frame of your project nearest the raise, with the path relative to the directory the run started in. It skips frames in a gem, in Ruby's library, and in quint_driver, so an error a gem raises names your line that called the gem. That line is usually the one to fix; for a domain error the driver should rescue, it is where the error came from. When every frame is skipped, the line reads `raised in: no frame of the project; every frame is in a gem, in Ruby's library, or in quint_driver`; read the backtrace then. The backtrace is the error's, and `cause` is the original error. Here a driver like the one in section 2 reads `picks.fetch("member")`, but the pick is named `m`:

  ```text
  quint: at step 1 `borrow` {"b" => "b2", "m" => "m2"}, the step raised KeyError: key not found: "member"
  raised in: loans_driver.rb:6:in 'Hash#fetch'
  steps:
    init {}
    borrow {"b" => "b2", "m" => "m2"}
  trace: trace_0.itf.json of Quint.simulate("spec.qnt", traces: 50, max_steps: 20, seed: "1", main: "loans", step: "step", backend: "rust")
  ```

  Under Hegel the line reads the same, and the number is the one Hegel's report gives the move (`Step 1: borrow`). A rule Hegel rejected counts too, so the number can be larger than the moves under `steps:`. A failure while the `driver:` lambda makes the driver, or at its first state, reads ``quint: at step 0 `init` {}, ...``, as on a replay. The machine makes its driver when it starts, so Hegel's report for that failure lists no step.
- Under Hegel, there is no seed: Hegel's report ends with `To reproduce this failure, pass the blob below to Hegel.test:` and a blob. Pass it as `Hegel.test(reproduce_failure: "...")` to run that one case again with the same message.
- Under Hegel, `steps:` is the shrunk sequence. Hegel's own report names each draw after the pick it chose, and under `choose: :rotate` names the turn `rule` and the move `move`. A label drawn more than once in a test case is numbered in draw order (`m_1 = "m2"`, `m_2 = "m1"`); a label drawn once prints bare (`m = "m2"`).

| Error | Cause |
| --- | --- |
| `QuintDriver::Mismatch` | The system and the spec disagree, or the model cannot take a move a trace took, such as a pick its domain does not hold. |
| `QuintDriver::StepRaised` | The driver's `step` or `state`, the system it called, or the `driver:` lambda raised. `raised in:` names your project's frame. `cause` holds the error. |
| `QuintDriver::Unsupported` | The spec uses an operator the model does not evaluate, a move names no action of `step`, or a move lacks a pick its action needs. |
| `ArgumentError` | `QuintDriver.machine`'s `step:`, or `spec.rules`, names no action of the module. The message lists the actions it has. |
| `QuintDriver::QuintFailed` | quint rejected the spec, `main:` names no module of the file (the message lists the modules it has), the `QUINT` command is not installed, `QUINT` is unset and npx could not fetch quint, or the `QUINT_EVALUATOR` evaluator cannot run or answers in a format other than v0.7.0's. |
