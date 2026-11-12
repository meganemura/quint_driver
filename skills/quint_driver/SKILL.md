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
gem "quint_driver"
gem "hegeltest", "= 0.5.1" # only for step 5
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

- Write `step` as `any { ... }` whose arms call named actions, even for one action: `action step = any { tick }`. Without `any`, Quint names every move `step`, so a driver cannot tell the moves apart, and replay through the model raises `QuintDriver::Unsupported`. One `all` around the picks and the `any` reads the same: `action step = all { nondet x = S.oneOf() any { add(x), sub(x) } }`. An `all` that also holds a condition is refused, because no rule carries the condition.
- Take arguments only from `nondet x = S.oneOf()` before the call: `nondet b = BOOKS.oneOf() any { give_back(b), give_back_refused(b) }`.
- Draw each pick in the arm whose action takes it. A pick drawn above `any` is in the `picks` of every arm, so a failure lists it on a move that does not use it.
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
- `picks` holds the nondet values by name. A pick the move did not make is absent, and one it made of the spec's own `None` is present as `nil`, so read one an action may go without as `picks["b"]`, which is `nil` then, and one it needs as `picks.fetch("b")`.
- A refused twin runs the same command. Rescue the domain error into the spec's refusal value.
- A value the spec derives, a `val` or a `def` without parameters, is in no trace state. To compare one, name it in `observe:` (section 3) and return it from `state` under its name.
- `state` returns every variable of the spec. A variable it leaves out fails the step, so a forgotten one cannot pass. A variable the driver only reads, such as what a remote service answers, goes in `ignore:` (section 3). The values are plain: a set is a `Set`, a map a `Hash`, a tuple or a list an `Array`, a record a `Hash` with string keys, and a sum type its tag, or `[tag, value]` when it carries one. An Option, a sum type with the cases `None` and `Some`, is `nil` or the value itself.

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

The driver is held to every variable of the trace's state. One its `state` leaves out fails at the first step, `init`:

```text
quint: after step 0 `init` {}, the driver differs from the trace
  count: trace 0, but the driver's state leaves count out; report it, or name it in ignore: when the driver only reads it
```

A spec can model the world outside the code, such as what a remote service answers, in variables the driver reads to set up its stubs and cannot read back from the code. Name those in `ignore:`, and they are not compared: `Trace.replay(path, driver, ignore: %w[remote jobUp])`, or `QuintDriver.machine(spec, driver:, ignore: %w[remote jobUp])`. A name that is not a variable raises `ArgumentError` with the variables there are. "A driver for code that calls remote services" below shows the whole shape.

A trace holds only the variables, so a definition the spec derives from them, such as a total, is compared only when you observe it: `Trace.replay(path, driver, spec:, observe: %w[approvedSum])`, or `QuintDriver.machine(spec, driver:, observe: %w[approvedSum])`. The driver's `state` reports each observed name beside the variables, and is held to the value the definition has in each state. A driver that leaves it out fails with `approvedSum: model 0, but the driver's state leaves approvedSum out; report it, since observe: names it`. The model evaluates the definition, on a replay too, so the line names the model, such as `approvedSum: model 0, driver 15000`. A name `state` reports that is in no state fails as `dueCents: driver 0, but dueCents is not in the trace's state, which has ...`, and when the name is a definition of the spec the line says to name it in `observe:`. A name that is no `val` or `def` without parameters raises `ArgumentError` with the names the module has. The Rails section below holds a total to one.

To test the steps that lead to one state, write a definition that holds there and pass its name as `reach:`. Each trace then ends at the first state where it holds, and only the traces that get there are yielded:

```ruby
# In loans.qnt: val two_on_loan = BOOKS.filter(b => onLoan(holder, b)).size() == 2
QuintDriver::Quint.simulate("spec.qnt", main: "loans", traces: 20, max_steps: 10, seed: "1", reach: "two_on_loan") do |path|
  QuintDriver::Trace.replay(path, LoansDriver.new)
end
```

One of those traces runs `init give_back_refused borrow borrow`. When no trace gets there, `Quint.simulate` raises `QuintDriver::QuintFailed`: `quint: no trace of 20 reached two_on_loan within 1 steps; raise max_steps or traces`. Raise `max_steps` or `traces` then. `reach:` takes a predicate (a boolean `val` or `def` without parameters) and `step:` an action without parameters; a name of another kind, such as an action as `reach:`, raises `ArgumentError` before quint runs, and the message lists the names that fit. A name the module neither declares nor imports, such as a typo, raises the same `ArgumentError` once quint has run: `quint: step names borow, which loans neither declares nor imports; step takes an action without parameters, such as step`.

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

Hegel trusts the Ruby evaluation of the spec. Hold the model to Quint's own traces first. A module that imports, such as a test module that imports the spec's actions, reads what it imports as its own, also a definition that nothing in it reaches, and needs no action named `step`:

```ruby
spec = QuintDriver::Spec.new("spec.qnt", main: "loans")
QuintDriver::Quint.simulate("spec.qnt", main: "loans", traces: 200, max_steps: 30, seed: "7") do |path|
  QuintDriver::Trace.replay(path, spec.model)
end
```

`spec.model` is the one way to build a model. It evaluates sets, maps (`Map`, `get`, `keys`, `put`, `mapBy`, `set`, `setBy`, `setToMap`), records, tuples, lists (`append`, `concat`, `head`, `tail`, `length`, `nth`, `indices`, `replaceAt`, `slice`, `range`, `select`, `foldl`, and `foldr`, which Quint's docs leave out but both evaluators define as `(x, acc) => ...` from the right), sum types, integers (`/` and `%` only on non-negative operands, because Quint's evaluators truncate and Ruby floors), and booleans, with `Bool` as the set of `false` and `true`. `Int` and `Nat` are infinite, so the model cannot list the picks of a move drawn from them and raises `QuintDriver::Unsupported`: `quint: no evaluation for the name Nat in step; Nat is infinite, so no move can list its picks; draw from a finite set such as 0.to(9)`. An operation Quint's docs leave undefined, such as `head` of an empty list, raises `QuintDriver::Unsupported` too, and so does `get`, `set`, or `setBy` at a key the map does not have. An operator the model does not evaluate raises `QuintDriver::Unsupported`, and the message names the action or definition that holds it, such as `quint: no evaluation for operator powerset in subsets`. Go on to step 5 only when this passes. `model.moves(rule)` lists the `[action, picks, next state]` moves a rule of `spec.rules("step")` allows now, and `model.enter(next_state)` takes one. `model.value(node, env)` evaluates one IR node of a rule, and a refusal names the action the node is written in; for a node no definition holds, it says the node is `outside any definition`.

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

For a first spec in an app, start from one status column and the method that changes it: the README's quick start writes `spec/quint/loan_state.qnt` with one variable, `init`, and two actions, and a driver that creates the record in `init` and reads the column back with `reload`.

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

The spec is `examples/loans/loans.qnt`, which the gem ships (`bundle info --path quint_driver` prints where), copied to `spec/quint/loans.qnt`. The spec path is relative, because RSpec runs from the app's root:

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

### With ActiveRecord and a test database

The same shape runs on a real ActiveRecord model in a Rails 8.1 app with rspec-rails, factory_bot_rails, transactional fixtures, and SQLite or PostgreSQL. This run is on Ruby 3.3, so it replays traces only; Hegel needs Ruby 3.4. The app's `Loan` belongs to a `Borrower` with a `limit`, validates `amount > 0`, and `Loan#approve(officer)` answers `:already`, `:over_limit` when the borrower's approved loans and this one pass the limit, `:needs_senior` above 10,000 for an officer who is not senior, or `:approved` after `update!(approved_at:, approved_by:)`.

Name the records in the spec (`l1`, `l2`) and keep the id that `create!` returns for each name, because ids keep growing from one trace to the next. Put the amounts at each limit the code compares with (10,000, and 20,000 in two loans), or a `>` written as `>=` passes every trace:

```quint
// spec/quint/loan.qnt: one borrower's loans and their approval.
module loan {
  val LOANS = Set("l1", "l2", "l3")
  val AMOUNTS = Set(0, 5000, 10000, 15000)
  val OFFICERS = Set("grace", "ada")
  val SENIOR = Set("grace")
  val LIMIT = 20000

  type Outcome = Done | Invalid | Approved | Already | OverLimit | NeedsSenior

  var amount: str -> int
  var approvedBy: str -> str
  var outcome: Outcome

  def requested(l) = amount.get(l) > 0
  def approvedSum = LOANS.filter(l => approvedBy.get(l) != "").fold(0, (sum, l) => sum + amount.get(l))
  def decision(l, o) =
    if (approvedBy.get(l) != "") Already
    else if (approvedSum + amount.get(l) > LIMIT) OverLimit
    else if (amount.get(l) > 10000 and not(SENIOR.contains(o))) NeedsSenior
    else Approved

  action init = all {
    amount' = LOANS.mapBy(_ => 0),
    approvedBy' = LOANS.mapBy(_ => ""),
    outcome' = Done,
  }

  action request(l, a) = all {
    not(requested(l)),
    amount' = if (a > 0) amount.set(l, a) else amount,
    approvedBy' = approvedBy,
    outcome' = if (a > 0) Done else Invalid,
  }

  action approve(l, o) = all {
    requested(l),
    amount' = amount,
    approvedBy' = if (decision(l, o) == Approved) approvedBy.set(l, o) else approvedBy,
    outcome' = decision(l, o),
  }

  action step = any {
    nondet l = LOANS.oneOf()
    nondet a = AMOUNTS.oneOf()
    request(l, a),
    nondet l = LOANS.oneOf()
    nondet o = OFFICERS.oneOf()
    approve(l, o),
  }

  val withinLimit = approvedSum <= LIMIT
}
```

The driver makes its records with the app's factories, so a record gets every attribute the factory sets, and rescues the validation error into the spec's `Invalid`:

```ruby
# spec/quint/loan_driver.rb
class LoanDriver
  LOANS = %w[l1 l2 l3].freeze
  OFFICERS = { "grace" => { name: "grace", senior: true }, "ada" => { name: "ada", senior: false } }.freeze
  OUTCOMES = { approved: "Approved", already: "Already", over_limit: "OverLimit", needs_senior: "NeedsSenior" }.freeze

  def step(action, picks)
    @outcome = "Done"
    case action
    when "init"
      @borrower = FactoryBot.create(:borrower, limit: 20_000)
      @ids = {}
    when "request"
      @ids[picks.fetch("l")] = FactoryBot.create(:loan, borrower: @borrower, amount: picks.fetch("a")).id
    when "approve"
      @outcome = OUTCOMES.fetch(Loan.find(@ids.fetch(picks.fetch("l"))).approve(OFFICERS.fetch(picks.fetch("o"))))
    end
  rescue ActiveRecord::RecordInvalid
    @outcome = "Invalid"
  end

  def state
    loans = LOANS.to_h { [ _1, @ids[_1] && Loan.find(@ids[_1]) ] }
    { "amount" => loans.transform_values { _1&.amount || 0 },
      "approvedBy" => loans.transform_values { _1&.approved_by || "" },
      "outcome" => @outcome }
  end
end
```

With `quint_driver` in the Gemfile's `:test` group, `Bundler.require` in `config/application.rb` loads it, so the spec file needs only `rails_helper`. With `require: false` on that line, as the README's quick start writes it so the app does not load the gem outside the specs, add `require "quint_driver"` after `rails_helper`. `Rails.root.join` names the spec from any directory RSpec starts in, and a failure still prints it relative to the app's root:

```ruby
# spec/quint/loan_spec.rb
require "rails_helper"
require_relative "loan_driver"

RSpec.describe Loan, "held to loan.qnt" do
  def rolled_back
    ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
      yield
      raise ActiveRecord::Rollback
    end
  end

  it "decides every approval the way the spec does" do
    outcomes = Set.new
    QuintDriver::Quint.simulate(Rails.root.join("spec/quint/loan.qnt"), traces: 50, max_steps: 12, seed: "1") do |path|
      rolled_back { QuintDriver::Trace.replay(path, LoanDriver.new).each { outcomes << _1.expected["outcome"] } }
    end

    expect(outcomes).to include("Approved", "Already", "OverLimit", "NeedsSenior", "Invalid")
    expect(Loan.count).to eq(0)
  end
end
```

```text
$ bundle exec rspec spec/quint
.

Finished in 2.41 seconds (files took 1.59 seconds to load)
1 example, 0 failures
```

`expect(Loan.count).to eq(0)` shows that every trace rolled back. With `amount > 10_000` written as `amount >= 10_000` in `Loan#approve`, the same example fails:

```text
QuintDriver::Mismatch:
  quint: after step 3 `approve` {"l" => "l1", "o" => "ada"}, the driver differs from the trace
    approvedBy: trace {"l1" => "ada", "l2" => "", "l3" => ""}, driver {"l1" => "", "l2" => "", "l3" => ""}
    outcome: trace "Approved", driver "NeedsSenior"
  steps:
    init {}
    request {"a" => 10000, "l" => "l1"}
    request {"a" => 5000, "l" => "l2"}
    approve {"l" => "l1", "o" => "ada"}
  trace: trace_3.itf.json of Quint.simulate("spec/quint/loan.qnt", traces: 50, max_steps: 12, seed: "1", step: "step", backend: "rust")
```

Transactional fixtures roll back once, after the example, not after each trace or Hegel test case. A row one trace writes is still there in the next, so the driver deletes the rows at `init`, or each trace and each test case rolls back to a savepoint:

```ruby
def rolled_back
  ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
    yield
    raise ActiveRecord::Rollback
  end
end

QuintDriver::Quint.simulate(spec_file, main: "loan", traces: 50, max_steps: 12, seed: "1") do |path|
  rolled_back { QuintDriver::Trace.replay(path, LoanDriver.new) }
end
Hegel.test(test_cases: 100, seed: 1, suppress_health_check: %i[filter_too_much too_slow]) do |tc|
  rolled_back { Hegel::Stateful.run(machine.new, tc) }
end
```

With `rolled_back`, the driver's `init` needs no `delete_all`. Pass `joinable: false`. A joinable savepoint takes in the model's own `transaction` blocks, so a `raise ActiveRecord::Rollback` inside one rolls nothing back: a loan that a model transaction approved and then rolled back read `"approved"` under `transaction(requires_new: true)`, and `"requested"` under `joinable: false`, as under the fixture's transaction alone.

A driver that neither deletes nor rolls back fails at init when its `state` reads the rows an earlier trace or test case left:

```text
quint: after step 0 `init` {}, the driver differs from the model
  outstanding: model 0, driver 500100
steps:
  init {}
```

`LoanDriver` above passes without `rolled_back` too, because its `init` makes a new borrower and `state` reads only the loans it made: the example left 145 loans behind for the fixture's rollback. Keep `rolled_back` anyway. App code that reads past the borrower, such as a count of all loans, sees the rows of earlier traces, and the failure then names a move, not the leftover rows.

On 4 CPUs at load average 1.3 to 1.6, a trace of 13 steps took 15 ms on SQLite and 35 ms on PostgreSQL, and a Hegel test case 25 ms and 42 ms. Deleting at init and rolling back to a savepoint took the same time within 10%.

### A value the spec derives

`loan.qnt` derives the approved total with `def approvedSum = LOANS.filter(l => approvedBy.get(l) != "").fold(0, (sum, l) => sum + amount.get(l))`. No variable holds it, so the example above passes while the page's total is wrong. Observe it:

```ruby
# app/models/borrower.rb
class Borrower < ApplicationRecord
  has_many :loans

  # What the borrower's page shows as approved so far.
  def approved_total = loans.where.not(approved_at: nil).sum(:amount)
end

# spec/quint/observe_spec.rb
require "rails_helper"
require_relative "loan_driver"

class ObservedLoanDriver < LoanDriver
  def state = super.merge("approvedSum" => @borrower.reload.approved_total)
end

RSpec.describe Borrower, "held to loan.qnt's approvedSum" do
  def rolled_back
    ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
      yield
      raise ActiveRecord::Rollback
    end
  end

  it "totals the approved loans the way the spec does" do
    qnt = Rails.root.join("spec/quint/loan.qnt")
    spec = QuintDriver::Spec.new(qnt, main: "loan")
    QuintDriver::Quint.simulate(qnt, traces: 50, max_steps: 12, seed: "1") do |path|
      rolled_back { QuintDriver::Trace.replay(path, ObservedLoanDriver.new, spec:, observe: %w[approvedSum]) }
    end
  end
end
```

With `approved_total` written as `loans.sum(:amount)`, which counts the loans not approved yet, the example fails at the first request:

```text
QuintDriver::Mismatch:
  quint: after step 1 `request` {"a" => 15000, "l" => "l1"}, the driver differs from the model
    approvedSum: model 0, driver 15000
  steps:
    init {}
    request {"a" => 15000, "l" => "l1"}
  trace: trace_0.itf.json of Quint.simulate("spec/quint/loan.qnt", traces: 50, max_steps: 12, seed: "1", step: "step", backend: "rust")
```

### A driver for code that calls remote services

Here a job and a JSON endpoint both ask a carrier's tracking service for a shipment's status:

```ruby
# app/services/carrier_api.rb: the carrier's tracking service. Specs stub it.
module CarrierApi
  class Unavailable < StandardError; end

  def self.status_of(ref) = raise(NotImplementedError, "calls the carrier over HTTP for #{ref}")
end

# app/models/shipment.rb
class Shipment < ApplicationRecord
  # Takes the carrier's status. While the carrier is down, keeps the old one.
  def sync_status!
    update!(status: CarrierApi.status_of(ref))
  rescue CarrierApi::Unavailable
    false
  end
end

# app/jobs/sync_shipment_job.rb
class SyncShipmentJob < ApplicationJob
  def perform(shipment) = shipment.sync_status!
end

# app/controllers/shipments_controller.rb, routed as post "/shipments/:ref/sync"
class ShipmentsController < ApplicationController
  def sync
    shipment = Shipment.find_by!(ref: params[:ref])
    shipment.sync_status!
    render json: { ref: shipment.ref, status: shipment.status }
  end
end
```

The spec holds the outside world as variables: `remote`, what the service answers for each shipment, and `carrierUp`, whether it answers at all. The actions `setRemote` and `setCarrierUp` change only those. `calls` counts the calls the code makes, failed ones too, so the spec checks that a call happened, and happened once:

```quint
// spec/quint/shipment.qnt
module shipment {
  pure val REFS = Set("s1", "s2")
  pure val ANSWERS = Set("in_transit", "delivered")

  var remote: str -> str
  var carrierUp: bool
  var status: str -> str
  var calls: int

  action init = all {
    remote' = REFS.mapBy(_ => "in_transit"),
    carrierUp' = true,
    status' = REFS.mapBy(_ => "pending"),
    calls' = 0,
  }

  action setRemote(s: str, a: str): bool = all { remote' = remote.set(s, a), carrierUp' = carrierUp, status' = status, calls' = calls }
  action setCarrierUp(u: bool): bool = all { carrierUp' = u, remote' = remote, status' = status, calls' = calls }

  action sync(s: str): bool = all {
    calls' = calls + 1,
    status' = if (carrierUp) status.set(s, remote.get(s)) else status,
    remote' = remote,
    carrierUp' = carrierUp,
  }
  action syncByJob(s: str): bool = sync(s)
  action syncByApi(s: str): bool = sync(s)

  action step = any {
    nondet s = REFS.oneOf()
    nondet a = ANSWERS.oneOf()
    setRemote(s, a),
    nondet u = Bool.oneOf()
    setCarrierUp(u),
    nondet s = REFS.oneOf()
    syncByJob(s),
    nondet s = REFS.oneOf()
    syncByApi(s),
  }
}
```

The driver keeps the world, answers the stubbed calls from it, and counts them. It gets the example, so it can make the request. A response that is not 2xx raises, so an unexpected 4xx or 5xx is a `StepRaised` that names the step, not a mismatch:

```ruby
# spec/quint/shipment_driver.rb
class ShipmentDriver
  REFS = %w[s1 s2].freeze

  # +example+ is the RSpec example, which makes the requests.
  def initialize(example) = @example = example

  def answer_for(ref)
    @calls += 1
    raise CarrierApi::Unavailable unless @carrier_up

    @remote.fetch(ref)
  end

  def step(action, picks)
    case action
    when "init"
      Shipment.delete_all
      REFS.each { Shipment.create!(ref: _1) }
      @remote, @carrier_up, @calls = REFS.to_h { [ _1, "in_transit" ] }, true, 0
    when "setRemote" then @remote[picks.fetch("s")] = picks.fetch("a")
    when "setCarrierUp" then @carrier_up = picks.fetch("u")
    when "syncByJob" then SyncShipmentJob.perform_now(Shipment.find_by!(ref: picks.fetch("s")))
    when "syncByApi"
      @example.post "/shipments/#{picks.fetch("s")}/sync"
      response = @example.response
      raise "POST answered #{response.status}: #{response.body}" unless response.successful?
    end
  end

  # remote and carrierUp are not here: the example names them in ignore:.
  def state = { "status" => Shipment.pluck(:ref, :status).to_h, "calls" => @calls }
end
```

The example stubs the service once, in `before`, with a block that asks the driver. The driver is a `let`, so the stub and the replay share it, and its `init` resets the world for each trace:

```ruby
# spec/quint/shipment_spec.rb
require "rails_helper"
require_relative "shipment_driver"

RSpec.describe "Shipment status held to shipment.qnt", type: :request do
  let(:driver) { ShipmentDriver.new(self) }

  before { allow(CarrierApi).to receive(:status_of) { |ref| driver.answer_for(ref) } }

  it "follows the carrier through the job and the endpoint" do
    qnt = Rails.root.join("spec/quint/shipment.qnt")
    QuintDriver::Quint.simulate(qnt, traces: 30, max_steps: 12, seed: "1") do |path|
      QuintDriver::Trace.replay(path, driver, ignore: %w[remote carrierUp])
    end
  end
end
```

Without `ignore:`, the replay fails at `init` and names `carrierUp` and `remote`. Under the machine, pass the same list: `QuintDriver.machine(spec, driver: -> { driver }, ignore: %w[remote carrierUp])`. With a `sync_status!` that retries once while the carrier is down, Hegel shrinks the failure to:

```text
QuintDriver::Mismatch:
  quint: after step 2 `syncByJob` {"s" => "s1"}, the driver differs from the model
    calls: model 1, driver 2
  steps:
    init {}
    setCarrierUp {"u" => false}
    syncByJob {"s" => "s1"}
```

A driver that reads `flash` and follows no redirect starts a new session for each step: `@example.reset!`, then sign in again. A flash a step sets before its redirect is still there in the next request, so the next step sees two outcomes. Reading the outcome from the response or the rows works too.

### A choice the code leaves to the database

Here a job reads a batch's items through `has_many` with no ORDER BY, and the order decides which item gets the free slot:

```ruby
# app/models/batch.rb
class Batch < ApplicationRecord
  has_many :items, autosave: true
end

# app/jobs/assign_slots_job.rb
class AssignSlotsJob < ApplicationJob
  def perform(batch)
    free = batch.free
    batch.items.each do |item|
      next if item.state.in?(%w[assigned done])

      if free > 0
        item.state = "assigned"
        free -= 1
      else
        item.state = "waiting"
      end
    end
    batch.update!(free:)
  end
end
```

Without ORDER BY, the database returns the rows in no fixed order. SQLite returned them in the order they were made. PostgreSQL 16 did so too on an index scan, but on a sequential scan, which it chose for a small table, it returned a row after the others once the row was updated. A spec that walks the items in one fixed order then fails a replay where the code is right. Make the order a pick of the action: the spec lists the orders the database may return, and `step` picks one.

```quint
// spec/quint/slots.qnt: a batch gives its free slots to its items.
module slots {
  pure val ITEMS = Set("i1", "i2", "i3")
  // Every order the database may return the three items in.
  pure val ORDERS = Set(
    ["i1", "i2", "i3"], ["i1", "i3", "i2"], ["i2", "i1", "i3"],
    ["i2", "i3", "i1"], ["i3", "i1", "i2"], ["i3", "i2", "i1"],
  )

  var state: str -> str
  var blocked: str -> bool
  var free: int
  var outcome: str

  action init = all {
    state' = ITEMS.mapBy(_ => "pending"),
    blocked' = ITEMS.mapBy(_ => false),
    free' = 1,
    outcome' = "ok",
  }

  action block(i: str): bool = all {
    state' = state, blocked' = blocked.set(i, true), free' = free, outcome' = "ok",
  }

  // One item's turn of the job: a slot while one is free, else it waits.
  def give(acc: (str -> str, int), i: str): (str -> str, int) =
    if (acc._1.get(i) == "assigned" or acc._1.get(i) == "done") acc
    else if (acc._2 > 0) (acc._1.set(i, "assigned"), acc._2 - 1)
    else (acc._1.set(i, "waiting"), acc._2)

  // The job reads the items with no ORDER BY, so the order is a pick.
  action runJob(order: List[str]): bool = {
    val walked = order.foldl((state, free), give)
    val invalid = ITEMS.exists(i => blocked.get(i) and state.get(i) != "assigned" and walked._1.get(i) == "assigned")
    all {
      state' = if (invalid) state else walked._1,
      free' = if (invalid) free else walked._2,
      blocked' = blocked,
      outcome' = if (invalid) "invalid" else "ok",
    }
  }

  action release(i: str): bool = all {
    state' = if (state.get(i) == "assigned") state.set(i, "done") else state,
    free' = if (state.get(i) == "assigned") free + 1 else free,
    blocked' = blocked,
    outcome' = if (state.get(i) == "assigned") "ok" else "refused",
  }

  action step = any {
    nondet i = ITEMS.oneOf()
    block(i),
    nondet order = ORDERS.oneOf()
    runJob(order),
    nondet i = ITEMS.oneOf()
    release(i),
  }
}
```

Three items have six orders, and n rows have n! orders. With more rows, list only the orders that lead to different states. Here at most one slot is free, so only the first item that is neither assigned nor done gets it, and the order of the rest changes nothing. `Item` validates that a blocked item is not assigned, so a run that would assign one is `invalid` and changes nothing.

The driver enacts the pick on the loaded association. While the job runs, `in_order` loads the association's target and sorts it in place; at any other time it returns the association untouched. Its `release` step goes through a page, so it starts a new session first:

```ruby
# spec/quint/slots_driver.rb
class SlotsDriver
  ITEMS = %w[i1 i2 i3].freeze

  # +example+ is the RSpec example, which makes the requests.
  def initialize(example) = @example = example

  # Batch#items while the job runs: the loaded items, sorted in place into the order the step picked.
  def in_order(items)
    return items unless @order

    items.load_target
    items.target.sort_by! { @order.index(_1.id) }
    items
  end

  def step(action, picks)
    @outcome = "ok"
    case action
    when "init"
      @batch = Batch.create!(free: 1)
      @ids = ITEMS.to_h { [ _1, @batch.items.create!.id ] }
    when "block" then Item.find(@ids.fetch(picks.fetch("i"))).update!(blocked: true)
    when "runJob"
      @order = @ids.values_at(*picks.fetch("order"))
      AssignSlotsJob.perform_now(Batch.find(@batch.id))
    when "release"
      @example.reset!
      @example.post "/session", params: { name: "operator" }
      @example.patch "/items/#{@ids.fetch(picks.fetch("i"))}/release"
      raise "PATCH answered #{@example.response.status}" unless @example.response.redirect?

      @outcome = @example.flash[:notice] ? "ok" : "refused"
    end
  rescue ActiveRecord::RecordInvalid
    @outcome = "invalid"
  ensure
    @order = nil
  end

  def state
    items = Item.find(@ids.values).index_by(&:id)
    { "state" => @ids.transform_values { items.fetch(_1).state },
      "blocked" => @ids.transform_values { items.fetch(_1).blocked },
      "free" => @batch.reload.free,
      "outcome" => @outcome }
  end
end
```

The example wraps the reader once, in `before`. The driver is a `let`, so the wrap and the replay share it:

```ruby
# spec/quint/slots_spec.rb
require "rails_helper"
require_relative "slots_driver"

RSpec.describe "Batch slots held to slots.qnt", type: :request do
  let(:driver) { SlotsDriver.new(self) }

  before do
    allow_any_instance_of(Batch).to receive(:items).and_wrap_original { |reader, *args| driver.in_order(reader.call(*args)) }
  end

  def rolled_back
    ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
      yield
      raise ActiveRecord::Rollback
    end
  end

  it "gives the free slot in the order the step picked" do
    QuintDriver::Quint.simulate(Rails.root.join("spec/quint/slots.qnt"), traces: 50, max_steps: 10, seed: "1") do |path|
      rolled_back { QuintDriver::Trace.replay(path, driver) }
    end
  end
end
```

Without the wrap, the first trace fails at its first `runJob`, on SQLite and on PostgreSQL 16 alike:

```text
QuintDriver::Mismatch:
  quint: after step 1 `runJob` {"order" => ["i3", "i2", "i1"]}, the driver differs from the trace
    state: trace {"i1" => "waiting", "i2" => "waiting", "i3" => "assigned"}, driver {"i1" => "assigned", "i2" => "waiting", "i3" => "waiting"}
  steps:
    init {}
    runJob {"order" => ["i3", "i2", "i1"]}
```

Do not return `reorder(...)` from the wrap. A new relation loads records of its own, not the association's target, so the job changes records that `batch.update!` does not autosave. The same trace then fails with `driver {"i1" => "pending", "i2" => "pending", "i3" => "pending"}` while `free` drops to 0, and an item validation that fails no longer stops the update: with a blocked item that may not be assigned, `update!` raised `Validation failed: Items state blocked` when the job changed the loaded target, and saved when it changed the records of `reorder(:id)`.

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
- The backtrace of a `Mismatch` and of a `StepRaised` leaves out quint_driver's own frames, and under the machine Hegel's too. RSpec hides the frames of an installed gem but not of a gem the Gemfile loads from a path, and Minitest hides none, so without this the gem's frames would come first. The first line is the driver's or the system's raise, or the line of the spec that called `Trace.replay` or `Hegel.test`.
- An error a step raises, in the driver's own code or in the system beneath it, is a `QuintDriver::StepRaised`, not a `Mismatch`: the two sides were never compared. Fix the code the message points at first. A domain error the driver lets through, such as `Loans::Refused` on a `_refused` step, lands here too; rescue it into the spec's refusal value, as step 2 does. The first line names the step and the error. The `raised in:` line names the frame of your project nearest the raise, with the path relative to the directory the run started in. It skips frames in a gem, in Ruby's library, and in quint_driver, so an error a gem raises names your line that called the gem. That line is usually the one to fix; for a domain error the driver should rescue, it is where the error came from. When every frame is skipped, the line reads `raised in: no frame of the project; every frame is in a gem, in Ruby's library, or in quint_driver`; read the backtrace then. The backtrace is the error's without quint_driver's frames, and `cause` is the original error. Here a driver like the one in section 2 reads `picks.fetch("member")`, but the pick is named `m`:

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
| `ArgumentError` | `QuintDriver.machine`'s `step:`, or `spec.rules`, names no action of the module. The message lists the actions it has. Or the module has no action named `init`: every trace, model, and machine starts there, and no option names another, so add `action init = <the action that starts it>` to the spec. Its backtrace starts at your line that made the call. |
| `QuintDriver::QuintFailed` | quint rejected the spec (a failure at the flattening stage can come from another module of the file, as quint flattens every one), `main:` names no module of the file (the message lists the modules it has), the `QUINT` command is not installed, `QUINT` is unset and npx could not fetch quint, or the `QUINT_EVALUATOR` evaluator cannot run or answers in a format other than v0.7.0's. Its backtrace starts at your line that made the call. |
