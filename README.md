# quint_driver

quint_driver holds your Ruby code to a [Quint](https://github.com/quint-co/quint) spec: the spec says what each command must do, and quint_driver runs the same commands on your code and compares the two after every step.

## Quick start in your Rails app

### Add the gem

```ruby
# Gemfile
group :test do
  gem "quint_driver", require: false
end
```

```sh
bundle install
npm install --global @informalsystems/quint@0.33.0
```

quint_driver needs Ruby 3.3 or later. It calls the `quint` command that `QUINT` names, so the run below sets `QUINT=quint`; put `export QUINT=quint` in your shell profile to leave it out. Without `QUINT`, the gem runs `npx --yes @informalsystems/quint@0.33.0`, which downloads quint (43 MB) on its first run and starts node once more on every run. The first quint run also downloads quint's Rust evaluator from GitHub into `~/.quint`. When your network blocks that download, the [skill](skills/quint_driver/SKILL.md#install) shows how to fetch it by hand.

### Pick a first model

Pick a model with a status column, such as `state` or `status`, and a method that changes it, such as `Order#cancel` or `Loan#approve`. A model whose status a recent commit changed is a good start, because the spec then checks that change: `git log --oneline -- app/models` lists those commits.

The steps below use `Loan`. A new loan is `"pending"`, and `Loan#approve(officer)` makes it `"approved"`. Replace `Loan`, the record that the driver's `init` creates, the method, and the state names with yours.

### Write the spec

```quint
// spec/quint/loan_state.qnt
// A loan starts pending. Approving it once makes it approved, and
// approving it again leaves it approved.
module loan_state {
  var state: str

  action init = state' = "pending"
  action approve = all { state == "pending", state' = "approved" }
  action approve_refused = all { state == "approved", state' = state }

  action step = any { approve, approve_refused }
}
```

The `var` is the column. `init` is the value a new record has. Every other action is one call of the method, and its first condition says when the call does what the action says: `approve` makes a pending loan approved, and `approve_refused` leaves an approved loan as it is. `step` lists the actions that a trace picks from. `Quint.simulate` runs the module named after the file, so keep the two names the same.

### Write the driver

```ruby
# spec/quint/loan_state_driver.rb
# Runs each action of loan_state.qnt on a Loan and reads its state back.
class LoanStateDriver
  def step(action, _picks)
    case action
    when "init"
      borrower = Borrower.create!(name: "Ada", limit_cents: 20_000)
      @loan = Loan.create!(borrower: borrower, amount_cents: 500)
    when "approve", "approve_refused"
      @loan.approve({name: "Grace", senior: true})
    end
  end

  def state = {"state" => @loan.reload.state}
end
```

`step` runs one action on a real record: `init` creates it, and every other action calls the method. `state` returns the spec's variables, read back from the database.

### Write the example

```ruby
# spec/quint/loan_state_spec.rb
require "rails_helper"
require "quint_driver"
require_relative "loan_state_driver"

RSpec.describe Loan, type: :model do
  # The transactional fixture rolls back once, after the example. Each trace
  # rolls back to a savepoint of its own, so no trace sees the rows of another.
  def rolled_back
    ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
      yield
      raise ActiveRecord::Rollback
    end
  end

  it "moves its state the way loan_state.qnt says" do
    QuintDriver::Quint.simulate("spec/quint/loan_state.qnt", traces: 20, max_steps: 5, seed: "1") do |trace|
      rolled_back { QuintDriver::Trace.replay(trace, LoanStateDriver.new) }
    end
  end
end
```

Quint writes 20 traces of up to 5 steps, and each trace runs on a new loan.

### Run the example

```sh
QUINT=quint bundle exec rspec spec/quint/loan_state_spec.rb
```

## What you will see

This output is from a small sample app, a lending desk with a `Borrower` and a `Loan` model.

```text
.

Finished in 0.60298 seconds (files took 0.88104 seconds to load)
1 example, 0 failures
```

Every trace created a loan in the test database, approved it, approved it again, and read the state back after each step. After each step, the loan had the state the spec has.

Now a commit makes a new loan a draft:

```diff
--- a/app/models/loan.rb
+++ b/app/models/loan.rb
   def mark_pending
-    self.state ||= "pending"
+    self.state ||= "draft"
   end
```

```sh
QUINT=quint bundle exec rspec spec/quint/loan_state_spec.rb
```

```text
F

Failures:

  1) Loan moves its state the way loan_state.qnt says
     Failure/Error: rolled_back { QuintDriver::Trace.replay(trace, LoanStateDriver.new) }

     QuintDriver::Mismatch:
       quint: after step 0 `init` {}, the driver differs from the trace
         state: trace "pending", driver "draft"
       steps:
         init {}
       trace: trace_0.itf.json of Quint.simulate("spec/quint/loan_state.qnt", traces: 20, max_steps: 5, seed: "1", step: "step", backend: "rust")
     # ./spec/quint/loan_state_spec.rb:18:in 'block (4 levels) in <top (required)>'
     # ./spec/quint/loan_state_spec.rb:11:in 'block in RSpec::ExampleGroups::Loan#rolled_back'
     # ./spec/quint/loan_state_spec.rb:10:in 'RSpec::ExampleGroups::Loan#rolled_back'
     # ./spec/quint/loan_state_spec.rb:18:in 'block (3 levels) in <top (required)>'
     # ./spec/quint/loan_state_spec.rb:17:in 'block (2 levels) in <top (required)>'

Finished in 0.61377 seconds (files took 0.90689 seconds to load)
1 example, 1 failure

Failed examples:

rspec ./spec/quint/loan_state_spec.rb:16 # Loan moves its state the way loan_state.qnt says
```

The first line names the step where the model and the spec differ: right after `init`, the spec has a pending loan, and the model has a draft. `steps:` lists every step from `init`, so you can run the same commands by hand, and `trace:` names the call that writes the same trace again. When the change is a bug, fix the model. When the change is what you want, change `init` in the spec in the same commit, so the spec keeps saying what the app does.

Next, give an action a pick, such as the officer or the amount, and compare a second variable, such as the outcome of each call: [a bigger spec](#a-bigger-spec-refusals-and-picks) does both.

## A bigger spec: refusals and picks

The quick start's spec has one record and one variable. This spec of the same app has two loans of one borrower, picks the amount and the officer for each action, and compares the outcome of every call too. The driver keeps the id each loan of the spec got, and reads the rows back as the spec's variables. `Loan#approve(officer)` refuses a loan that is already approved, one over the borrower's limit, and one above 10000 cents when the officer is not senior:

```ruby
# spec/quint/approval_driver.rb
class ApprovalDriver
  LOANS = %w[l1 l2].freeze

  def step(action, picks)
    @outcome = "Done"
    case action.delete_suffix("_refused")
    when "init"
      @borrower = Borrower.create!(name: "Ada", limit_cents: 20_000)
      @ids = {}
    when "open"
      @ids[picks.fetch("l")] = LoanDesk.open(@borrower, picks.fetch("a")).id
    when "approve"
      officer = {name: "Grace", senior: picks.fetch("senior")}
      result = Loan.find(@ids.fetch(picks.fetch("l"))).approve(officer)
      @outcome = ["Refused", result.to_s] unless result == :approved
    end
  end

  def state
    loans = LOANS.to_h { [_1, @ids[_1] && Loan.find(@ids[_1])] }
    {
      "amount" => loans.transform_values { _1&.amount_cents || 0 },
      "approved" => loans.transform_values { _1&.state == "approved" },
      "outcome" => @outcome
    }
  end
end
```

A transactional fixture rolls back once, after the example, but one example replays many traces. Wrap each trace in a savepoint of its own, so no trace reads the rows of another:

```ruby
# spec/quint/approval_spec.rb
require "rails_helper"
require "quint_driver"
require_relative "approval_driver"

RSpec.describe Loan, type: :model do
  def rolled_back
    ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
      yield
      raise ActiveRecord::Rollback
    end
  end

  it "follows every trace Quint writes for approval.qnt" do
    QuintDriver::Quint.simulate("spec/quint/approval.qnt", traces: 50, max_steps: 8, seed: "1") do |path|
      rolled_back { QuintDriver::Trace.replay(path, ApprovalDriver.new) }
    end
  end
end
```

<details>
<summary>spec/quint/approval.qnt</summary>

```quint
// Two loans of one borrower with a limit of 20000 cents. A clerk approves
// up to 10000 cents, and a senior officer approves any amount. approve has
// a refused twin, so a trace checks the refusals too.
module approval {
  type Outcome = Done | Refused(str)

  pure val LOANS = Set("l1", "l2")
  pure val AMOUNTS = Set(500, 10000, 15000)
  pure val LIMIT = 20000

  // 0 means the loan is not open yet.
  var amount: str -> int
  var approved: str -> bool
  var outcome: Outcome

  pure def approvedCents(a: str -> int, ap: str -> bool): int =
    LOANS.filter(l => ap.get(l)).fold(0, (sum, l) => sum + a.get(l))
  pure def refusal(a: str -> int, ap: str -> bool, l: str, senior: bool): str =
    if (ap.get(l)) "already"
    else if (approvedCents(a, ap) + a.get(l) > LIMIT) "over_limit"
    else if (a.get(l) > 10000 and not(senior)) "needs_senior"
    else ""

  action init = all {
    amount' = LOANS.mapBy(_ => 0),
    approved' = LOANS.mapBy(_ => false),
    outcome' = Done,
  }

  action open(l: str, a: int): bool = all {
    amount.get(l) == 0,
    amount' = amount.put(l, a),
    approved' = approved,
    outcome' = Done,
  }
  action approve(l: str, senior: bool): bool = all {
    amount.get(l) > 0,
    refusal(amount, approved, l, senior) == "",
    amount' = amount,
    approved' = approved.put(l, true),
    outcome' = Done,
  }
  action approve_refused(l: str, senior: bool): bool = all {
    amount.get(l) > 0,
    refusal(amount, approved, l, senior) != "",
    amount' = amount,
    approved' = approved,
    outcome' = Refused(refusal(amount, approved, l, senior)),
  }

  action step = any {
    nondet l = LOANS.oneOf()
    nondet a = AMOUNTS.oneOf()
    any { open(l, a) },
    nondet l = LOANS.oneOf()
    nondet senior = Set(true, false).oneOf()
    any { approve(l, senior), approve_refused(l, senior) },
  }

  val within_limit = approvedCents(amount, approved) <= LIMIT
}
```

</details>

```sh
QUINT=quint bundle exec rspec spec/quint/approval_spec.rb
```

```text
.

Finished in 1.22 seconds (files took 0.91182 seconds to load)
1 example, 0 failures
```

Each of the 50 traces ran on the real models and the test database, and rolled back. When `Loan#approve` asks for a senior officer at exactly 10000 cents (`amount_cents >= 10_000` in place of `> 10_000`), the same command fails at the first trace that approves such a loan:

```text
     QuintDriver::Mismatch:
       quint: after step 6 `approve` {"l" => "l1", "senior" => false}, the driver differs from the trace
         approved: trace {"l1" => true, "l2" => true}, driver {"l1" => false, "l2" => true}
         outcome: trace "Done", driver ["Refused", "needs_senior"]
       steps:
         init {}
         open {"a" => 500, "l" => "l2"}
         approve {"l" => "l2", "senior" => false}
         open {"a" => 10000, "l" => "l1"}
         approve_refused {"l" => "l2", "senior" => false}
         approve_refused {"l" => "l2", "senior" => true}
         approve {"l" => "l1", "senior" => false}
       trace: trace_1.itf.json of Quint.simulate("spec/quint/approval.qnt", traces: 50, max_steps: 8, seed: "1", step: "step", backend: "rust")
```

To delete the rows in the driver's `init` instead of a savepoint, and for the reason the savepoint must not be joinable, see the [skill](skills/quint_driver/SKILL.md).

## Try it without an app

### Install

```sh
gem install quint_driver rspec
npm install --global @informalsystems/quint@0.33.0
export QUINT=quint
```

Here the gems install without a Gemfile. [Add the gem](#add-the-gem) says what `QUINT` does.

### Write a spec, a class, and a test

Run this in an empty folder. It writes three files: a spec of a box office that sells at most 3 tickets, the class that implements it, and an RSpec file with the driver that connects the two.

```sh
cat > tickets.qnt <<'QNT'
// A box office that sells at most 3 tickets.
module tickets {
  var sold: int
  var outcome: str

  action init = all { sold' = 0, outcome' = "ok" }
  action sell = all { sold < 3, sold' = sold + 1, outcome' = "ok" }
  action sell_refused = all { sold >= 3, sold' = sold, outcome' = "sold_out" }
  action refund = all { sold > 0, sold' = sold - 1, outcome' = "ok" }

  action step = any { sell, sell_refused, refund }
}
QNT

cat > box_office.rb <<'RUBY'
class BoxOffice
  LIMIT = 3

  attr_reader :sold

  def initialize = @sold = 0

  def sell
    return :sold_out if @sold >= LIMIT

    @sold += 1
    :ok
  end

  def refund
    @sold -= 1
    :ok
  end
end
RUBY

cat > box_office_spec.rb <<'RUBY'
require "quint_driver"
require_relative "box_office"

# Runs each action of tickets.qnt on a BoxOffice and reads it back as the spec's variables.
class BoxOfficeDriver
  def step(action, _picks)
    @office = BoxOffice.new if action == "init"
    @outcome =
      case action
      when "init" then "ok"
      when "sell", "sell_refused" then @office.sell.to_s
      when "refund" then @office.refund.to_s
      end
  end

  def state = { "sold" => @office.sold, "outcome" => @outcome }
end

RSpec.describe BoxOffice do
  it "sells tickets the way tickets.qnt says" do
    QuintDriver::Quint.simulate("tickets.qnt", traces: 20, max_steps: 10, seed: "1") do |trace|
      QuintDriver::Trace.replay(trace, BoxOfficeDriver.new)
    end
  end
end
RUBY
```

### Run it

```sh
rspec box_office_spec.rb
```

```text
.

Finished in 0.47699 seconds (files took 0.08795 seconds to load)
1 example, 0 failures
```

Quint wrote 20 traces of up to 10 steps each, and the driver ran every step on a new `BoxOffice`. After each step, the class had the same `sold` and `outcome` as the spec.

### Break it

Let the box office sell one ticket too many:

```sh
ruby -pi -e 'sub("@sold >= LIMIT", "@sold > LIMIT")' box_office.rb
rspec box_office_spec.rb
```

```text
F

Failures:

  1) BoxOffice sells tickets the way tickets.qnt says
     Failure/Error: QuintDriver::Trace.replay(trace, BoxOfficeDriver.new)

     QuintDriver::Mismatch:
       quint: after step 8 `sell_refused` {}, the driver differs from the trace
         sold: trace 3, driver 4
         outcome: trace "sold_out", driver "ok"
       steps:
         init {}
         sell {}
         refund {}
         sell {}
         sell {}
         refund {}
         sell {}
         sell {}
         sell_refused {}
       trace: trace_2.itf.json of Quint.simulate("tickets.qnt", traces: 20, max_steps: 10, seed: "1", step: "step", backend: "rust")
     # ./box_office_spec.rb:22:in 'block (3 levels) in <top (required)>'
     # ./box_office_spec.rb:21:in 'block (2 levels) in <top (required)>'

Finished in 0.5298 seconds (files took 0.08509 seconds to load)
1 example, 1 failure

Failed examples:

rspec ./box_office_spec.rb:20 # BoxOffice sells tickets the way tickets.qnt says
```

The first line names the step where the class and the spec disagree: at step 8, with 3 tickets sold, the spec refuses the sale, and the class sells a 4th. `steps:` lists every step from `init`, so you can run the same commands by hand, and `trace:` names the call that writes the same trace again. Fix the class and run `rspec` again.

Next, [write a driver](#write-a-driver) for your own class, or let [Hegel](#run-it-1) choose the steps and shrink a failure to the shortest sequence.

## How it works

There are two ways to choose the steps, and both use the same driver:

- **Trace replay.** `quint run --mbt` writes traces, and each trace runs on the system step by step. Quint picks the steps, so a trace reaches deep states quickly. The quick start uses this way.
- **Hegel.** [Hegel](https://github.com/meganemura/hegel-ruby) picks each step from the actions the spec allows now. When the system disagrees with the spec, Hegel shrinks the failure to a short sequence of commands.

The spec is read from Quint's JSON IR and evaluated inside the Ruby process, so a Hegel step does not start another process.

## Installation

```ruby
# Gemfile
gem "quint_driver"
gem "hegeltest", "= 0.5.1" # only for the Hegel adapter
```

Trace replay and the model load with `require "quint_driver"`. They need Ruby 3.3 or later and no other gem.

The Hegel adapter loads with `require "quint_driver/hegel"`. It needs hegeltest 0.5.1, which needs Ruby 3.4 or later. The gem does not depend on hegeltest, so add it to your own Gemfile.

The gem calls the `quint` command line that `QUINT` names, as the [quick start](#add-the-gem) shows. Without `QUINT`, the gem runs `npx --yes @informalsystems/quint@0.33.0`. When npx cannot fetch quint, for example offline, the gem raises `QuintDriver::QuintFailed` that says so and asks you to set `QUINT`.

`Spec.new` compiles a file once per process and quint command, and compiles it again when the text of the file, or of a file it imports, changes. Every module of the file shares that compile, so a `Spec.new` or `Quint.simulate` for another `main:` of the same file starts no node. Threads that ask for the same file at once wait for one compile, so a parallel test run needs no memo of its own.

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

The gem ships the skill and the `examples/loans` spec, so after `bundle install` you can copy or symlink the installed copy instead, with no GitHub access:

```sh
mkdir -p .agents/skills
ln -s "$(bundle info --path quint_driver)/skills/quint_driver" .agents/skills/quint_driver
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

  # Every variable of the spec, as plain Ruby values. One left out fails the step.
  def state
    { "holder" => %w[b1 b2 b3].to_h { [ _1, @loans.holder(_1) || "" ] }, "outcome" => @outcome }
  end
end
```

Plain values: a Quint set is a `Set`, a map a `Hash`, a tuple or a list an `Array`, a record a `Hash` with string keys, and a sum type its tag, or `[tag, value]` when it carries a value. A sum type with the cases `None` and `Some`, an Option, is `nil` for `None` and the value itself for `Some`, on a replay and under the machine alike.

A variable `state` leaves out fails the step and is named, such as `count: trace 0, but the driver's state leaves count out`, so a variable you forgot cannot pass. A spec can model the world outside your code, such as what a remote service answers, in variables the driver only reads to set up its stubs. Name those in `ignore:`, on `Trace.replay` or on `QuintDriver.machine`, and they are not compared.

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

Both raise `QuintDriver::Mismatch` with each variable that differs and the steps the driver ran from `init`, so you can run the failure again by hand. Each value prints with a set's elements and a hash's keys sorted, so the spec's side and the driver's side print a record in one key order. The message ends with a `trace:` line. After `Quint.simulate` returns, the file it replayed is gone, so the line names the trace by its file name and the call that writes the same trace again, such as `trace: trace_0.itf.json of Quint.simulate("loans.qnt", traces: 50, max_steps: 20, seed: "1", step: "step", backend: "rust")`. The error reads the same inside the block, and holds those facts as `trace`, `seed`, and `written_by`. A `Mismatch` your own code raises inside the block, such as from a check of your own after the replay, gets the same `trace:` line when it leaves the block. Raise it with a message alone, `raise QuintDriver::Mismatch, "..."`: `Mismatch.new` takes no trace, seed, or call, because the gem names the trace that ran. A replay of a trace file of your own names its path. The backtrace of a `Mismatch` leaves out quint_driver's own frames, and Hegel's under the machine, so RSpec and Minitest print first the line of yours that called the replay or `Hegel.test`, or that raised it, also when your Gemfile loads the gem from a path. A pick the move did not make is absent from `picks`, and a pick it made of the spec's own `None` is present as `nil`, so read a pick an action may go without as `picks["name"]`, which is `nil` then, and a pick it needs as `picks.fetch("name")`. `Trace.replay` returns the steps it ran, each with its `action`, `picks`, and `expected` state, so you can count what the traces reached. To watch a replay, pass `log: $stdout` to `Trace.replay`; it prints each step, such as `step 1 borrow {"b" => "b1", "m" => "m2"}`, before the driver runs it. The code runs the same in a Minitest test and in an RSpec example. In RSpec, include `Hegel::Syntax::Methods` if your own examples draw values; the machine itself does not need it. In a Rails app, transactional fixtures roll back once per example, so every trace and every Hegel test case of one example shares the test database: delete the rows in the driver's `init`, or wrap each trace and each test case in `ActiveRecord::Base.transaction(requires_new: true, joinable: false) { ...; raise ActiveRecord::Rollback }`. The skill shows both and why the savepoint must not be joinable.

A trace holds the spec's variables, not its definitions, so a value the spec derives, such as `def approvedSum` over the approved loans, is compared only when you observe it. Pass `observe: %w[approvedSum]` with `spec:` to `Trace.replay`, or `observe:` to `QuintDriver.machine`, and report the value in the driver's `state` under the same name, such as `"approvedSum" => borrower.approved_total`. The driver is held to the value the definition has in each state, and a driver that reports no value for it fails. The model evaluates the definition, also on a replay, where it reads the trace's state, so the failure names the model: `approvedSum: model 0, driver 15000`. A name the driver reports that is in no state fails too, such as `dueCents: driver 0, but dueCents is not in the trace's state, which has amount, approvedBy, outcome`; when the name is a definition of the spec, the line says to name it in `observe:`. A name that is no `val` or `def` without parameters raises `ArgumentError` with the ones the module has.

An error a step raises comes out as `QuintDriver::StepRaised`, not as a `Mismatch`, because the spec and the system were never compared. The error can come from the driver's own code, such as a `KeyError` from `picks.fetch("member")` when the pick is named `m`, or from the system beneath it. Its message names the step and the error, such as ``quint: at step 1 `borrow` {"b" => "b2", "m" => "m2"}, the step raised KeyError: key not found: "member"``. A `raised in:` line then names the frame of your project nearest the raise, such as `raised in: loans_driver.rb:6:in 'Hash#fetch'`, with the path relative to the directory the run started in. Frames in a gem, in Ruby's library, and in quint_driver are skipped, so an error that a gem raises names your line that called the gem. When every frame is skipped, the line says so: `raised in: no frame of the project; every frame is in a gem, in Ruby's library, or in quint_driver`. Then read the backtrace. Under Hegel the step number is the one Hegel's report gives the move, such as `Step 2: take`, and `init` is step 0, as on a replay. Then the message lists the steps from `init`, and on a replay ends with the same `trace:` line. Its backtrace is the error's without quint_driver's own frames, and `cause` is the error.

`Quint.simulate` runs the module named after the file. Pass `main:` to run another module of that file, the same name `Spec.new` takes. When quint fails or is not installed, `Spec.new` and `Quint.simulate` raise `QuintDriver::QuintFailed` with quint's reason. Its backtrace starts at the line of yours that called the gem, with no frame of quint_driver before it.

To test the steps that lead to one state, pass `reach:` the name of a definition that holds there, such as `reach: "two_on_loan"` for `val two_on_loan = BOOKS.filter(b => onLoan(holder, b)).size() == 2`. Each trace then ends at the first state where the definition holds, and `Quint.simulate` yields only the traces that get there. Quint checks `not(two_on_loan)` as the invariant and stops a trace where it breaks. When no trace gets there, it raises `QuintDriver::QuintFailed`, such as `quint: no trace of 20 reached two_on_loan within 1 steps; raise max_steps or traces`. `reach:` takes a predicate, a boolean `val` or `def` without parameters, and `step:` an action without parameters. A name of another kind raises `ArgumentError` before quint runs, such as `quint: reach names borrow, an action with parameters of loans; reach takes a predicate, a boolean val or def without parameters, such as nothing_on_loan, one_book_each, two_on_loan`. A name the module neither declares nor imports raises `ArgumentError` the same way once quint has run, such as `quint: step names borow, which loans neither declares nor imports; step takes an action without parameters, such as step`. `reach:` needs the default `backend: "rust"`. quint 0.33.0's typescript backend runs a trace on past the state where the definition first holds, and marks traces that never get there as ones that do, so `reach:` with `backend: "typescript"` raises `ArgumentError` before quint runs. Every trace, every model, and every machine starts at the action named `init`, as quint does by default. A module without one raises `ArgumentError`, such as ``quint: begins neither declares nor imports an action named init; quint_driver starts every trace and every model at init, so declare `action init = ...` with what starts begins``. quint_driver takes no other name for it: a trace names its first step after that action, and the driver and the model read that step as `init`. Add `action init = begin` to the module instead. The backtrace of each `ArgumentError` quint_driver raises starts at the line of yours that called it, with no frame of quint_driver before it.

An expectation is a predicate that should hold in every state, such as `val one_book_each = MEMBERS.forall(m => BOOKS.filter(b => holder.get(b) == m).size() <= 1)`. Pass its name in `invariants:` to `Trace.replay`, with `spec:`. The model evaluates it in each state of the trace, after the step's agreement check, and one that is false raises `QuintDriver::Violated`. That is not a `Mismatch`, and `rescue QuintDriver::Mismatch` does not catch it: the system agreed with the spec at every step, and the expectation still does not hold. The message names the expectation and the step, such as ``quint: the system agreed with the spec at every step, and the expectation `one_book_each` does not hold after step 4 `borrow` {"b" => "b3", "m" => "m2"}``. It lists the steps from `init` as a `Mismatch` does, gives the spec's variables in that state under `state:`, and ends with the same `trace:` line. A name that is no predicate raises `ArgumentError` before the first step, and so does `invariants:` without `spec:`.

`Quint.test(path, "lendTest", seed: "1") { |trace| ... }` writes the trace of a named run, such as `run lendTest = init.then(borrow("m1", "b1")).then(give_back("b1"))`, and yields its file; pass `main:` when the run is in another module of the file. quint test writes no `mbt::actionTaken`, so the spec has to record the action each step took, as a [Choreo](https://github.com/informalsystems/choreo) spec does: a variable that holds a sum type whose tag names the action and whose record holds its picks, such as `taken: Borrow({ m: m, b: b })`. Pass the path to that variable as `action:` to `Trace.replay`. When the state the driver answers for sits inside a variable, such as the `system` field of a Choreo spec's one variable, pass its path as `state:`; the driver's `state` then returns that record or map. `test/recorded.qnt` is a small spec of this shape, and `RecordedDriver` in `test/trace_test.rb` is its driver:

```ruby
QuintDriver::Quint.test("test/recorded.qnt", "lendTest", seed: "1") do |trace|
  QuintDriver::Trace.replay(trace, RecordedDriver.new, state: %w[s books], action: %w[s taken])
end
```

The driver gets `step("Init", {})`, then `step("Borrow", { "m" => "m1", "b" => "b1" })`, and so on. A failure names the trace as `trace: test_0.itf.json of Quint.test("test/recorded.qnt", "lendTest", seed: "1")`. A run that fails in quint itself raises `QuintDriver::QuintFailed` with quint's report, and a name that is no run of the module lists the runs it has, such as `quint: no run is named lend in recorded; it has lendTest, unlentTest`. A trace without the action, such as a quint test trace replayed without `action:`, raises `QuintDriver::Unsupported` that asks for the path.

`QuintDriver.machine` takes these options:

- `step:` is the action that lists the moves, `"step"` by default. Each move must call a named action. Arguments come from `nondet x = S.oneOf()`. A step that is one `all` around its picks and an `any`, such as `all { nondet x = S.oneOf() any { add(x), sub(x) } }`, moves by the actions of the `any`. A `step:` that is no action of the module raises `ArgumentError` with the actions it has, such as `quint: no action is named steps; the module has counting, init, step`.
- `invariants:` names expectations, predicates of the spec that should hold in every state, as `Trace.replay` takes them. Hegel checks them at `init` and after every move, after the move's agreement check. One that is false raises `QuintDriver::Violated` with the shrunk steps, such as ``quint: the system agreed with the spec at every step, and the expectation `one_book_each` does not hold after step 2 `borrow` {"b" => "b2", "m" => "m1"}``. A name that is no predicate raises `ArgumentError` from `QuintDriver.machine`.
- `choose:` is how Hegel draws a move. `:rule` (the default) picks an action and rejects it when the spec disables it. It shrinks to the shortest sequence. `:rotate` passes a disabled action's turn to the next enabled one. It reaches deep states with fewer test cases, but a shrunk sequence can keep extra moves. Hegel's failure report names each draw after the nondet pick it chose, or `rule` and `move` under `:rotate`. A label drawn more than once in a test case is numbered in draw order (`m_1 = "m2"`, `m_2 = "m1"`); a label drawn once prints bare (`m = "m2"`).

Each test case starts a new system through the driver's `init` when the machine starts, before Hegel's first step, so a driver that fails at `init` fails with no step in Hegel's report. A sequence of moves that the system already agreed on is not run again, because shrinking asks for the same sequence many times. This assumes that the system answers the same sequence the same way each time. A disagreement always runs on the system again.

A Hegel run has no Quint seed. Hegel's own report ends with a blob, such as `reproduce_failure: "AXicXYmhDQAADMJWu/3/70BgQJCmvdEWPwRiKlCBBwzbAGE="`; pass it to `Hegel.test` as `reproduce_failure:` to run that one failing case again, with the same message.

## Check the Ruby model

The Hegel way trusts the Ruby evaluation of the spec. The model answers the driver protocol, so you can hold it to Quint's own traces. A module that imports definitions or actions from another module or file reads them as its own, as quint does when it runs the module. It keeps every definition it imports, also one that nothing in the module reaches, and it needs no action named `step`; that costs one more compile for that module:

```ruby
QuintDriver::Quint.simulate("loans.qnt", traces: 200, max_steps: 30, seed: "7") do |path|
  QuintDriver::Trace.replay(path, spec.model)
end
```

The model evaluates the operators a command-per-action spec uses: sets (with `fold` and `i.to(j)`), maps, records, tuples, lists, sum types with `match`, integers, and booleans, with `Bool` as the set of `false` and `true`. `Int` and `Nat` are infinite, so the model cannot list the picks of a move drawn from them, and raises `QuintDriver::Unsupported`; draw from a finite set such as `0.to(9)` instead. On a map it evaluates `Map`, `get`, `keys`, `put`, `mapBy`, `set`, `setBy`, and `setToMap`. A list is a Ruby Array, and the model evaluates `List`, `append`, `concat`, `head`, `tail`, `length`, `nth`, `indices`, `replaceAt`, `slice`, `range`, `select`, `foldl`, and `foldr`. Quint's builtin docs leave `foldr` out, but both of its evaluators fold from the right and pass the element first, `(x, acc) => ...`, and the model does the same. On integers it evaluates `+`, `-`, `*`, unary `-`, and the comparisons, and `/` and `%` only on non-negative operands, because Quint documents no rounding for a negative one. Both of Quint's evaluators truncate toward zero (`-7 % 2` is `-1`), and Ruby floors (`-7 % 2` is `1`), so the model refuses a negative operand rather than answer differently. Where Quint's docs leave an operation undefined, such as `head` of an empty list, `nth` past the end, or `setToMap` of two pairs with one key, the model raises `QuintDriver::Unsupported` instead of picking an answer. `get`, `set`, and `setBy` at a key the map does not have raise it too, because Quint's evaluator stops there; `slice(l, l.length(), l.length())` is `[]`, as both of Quint's evaluators give it. Any other operator, such as `powerset`, raises `QuintDriver::Unsupported`, so a spec that needs more fails loudly. So does a step arm that names no action, and its message names the action that holds the arm, such as `quint: counting assigns n' in an arm that names no action; name every action in step` when `step` opens `counting` in place. The message names the action or definition that holds the operator, such as `quint: no evaluation for operator powerset in subsets`. For an operator in a nondet domain, that is the action that draws it, which can be an action that `step` opens in place.

`Spec#model` is the one way to build a model; `Model.new` is private, because the model trusts the shape of quint's compiled IR. A trace gives each pick as a plain value, and the model takes the value of the pick's domain that reads the same, so a pick of a sum type works in `match`.

`model.moves(rule)` lists every move a rule of `spec.rules("step")` allows in the model's current state, as `[action, picks, next state]` in a fixed order. `model.enter(next_state)` takes one. The Hegel machine draws its moves this way. `model.value(node, env)` evaluates one IR node, or the definition a string names, in the current state. A refusal names the definition that writes the node, such as the action a domain or an argument of a rule is written in; for a node no definition of the spec holds, the message says the node is `outside any definition`. `rule.fixed` is the set of domain names that are the same set in every state and after every earlier pick: Quint's effect of the domain reads no variable, and the domain names no earlier pick. The Hegel machine under `:rule` evaluates each of them once per machine.

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

`test/readme_test.rb` runs "Try it without an app" in an empty folder. It runs the Rails quick start and "What you will see" only when `QUINT_DRIVER_README_APP` names a Rails app to copy, with rspec-rails, `Borrower`, and `Loan` as in the sample app, and no quint_driver in its Gemfile. The test adds the gem built from this checkout, writes the files, runs the command, applies the diff, and compares each output with the README.

`test/skill_test.rb` runs the skill's example "A choice the code leaves to the database" only when `QUINT_DRIVER_SKILL_APP` names a Rails app to copy, with rspec-rails, an `Item` that belongs to a `Batch` and may not be assigned while blocked, the `/session` and `/items/:id/release` routes, and no quint_driver in its Gemfile. The test adds this checkout, writes the skill's files, replays the traces, then removes the wrap and compares the failure with the skill. It uses the app's database, so `DATABASE_URL` runs it on PostgreSQL.

## License

MIT

[Japanese](README.ja.md)
