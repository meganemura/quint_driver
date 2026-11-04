require_relative "test_helper"
require "fileutils"
require "stringio"
require "delegate"
require "json"

class TraceTest < Minitest::Test
  ANONYMOUS = File.expand_path("anonymous.qnt", __dir__)
  RECORDED = File.expand_path("recorded.qnt", __dir__)
  GEM_FRAME = /\A#{Regexp.escape(File.expand_path("../lib", __dir__))}\//

  # Runs Loans from recorded.qnt, whose one variable s holds the books and
  # the action each step took, as a Choreo spec keeps its state.
  class RecordedDriver
    attr_reader :ran

    def initialize(system = Loans) = (@system, @ran = system, [])

    def step(action, picks)
      @ran << [ action, picks ]
      case action
      when "Init" then @loans = @system.new
      when "Borrow" then @loans.borrow(picks.fetch("m"), picks.fetch("b"))
      when "GiveBack" then @loans.give_back(picks.fetch("b"))
      end
    end

    def state = %w[b1 b2].to_h { [ _1, @loans.holder(_1) || "" ] }
  end

  # Gives a book back and keeps its holder.
  class KeepingLoans < Loans
    def give_back(book) = @holders.fetch(book)
  end

  def test_decodes_itf_values_to_plain_ruby_values
    itf = {
      "set" => { "#set" => [ "a", "b" ] },
      "map" => { "#map" => [ [ "k", { "#bigint" => "7" } ] ] },
      "tuple" => { "#tup" => [ "a", 1 ] },
      "bare" => { "tag" => "Done", "value" => { "#tup" => [] } },
      "carrying" => { "tag" => "Refused", "value" => "on_loan" },
      "none" => { "tag" => "None", "value" => { "#tup" => [] } },
      "some" => { "tag" => "Some", "value" => "b1" },
      "record" => { "value" => { "#bigint" => "2" }, "full" => false },
      "#meta" => { "index" => 0 }
    }
    plain = {
      "set" => Set["a", "b"], "map" => { "k" => 7 }, "tuple" => [ "a", 1 ], "bare" => "Done",
      "carrying" => [ "Refused", "on_loan" ], "none" => nil, "some" => "b1", "record" => { "value" => 2, "full" => false }
    }

    assert_equal plain, QuintDriver::Trace.decode(itf)
  end

  def test_a_pick_the_move_did_not_make_is_absent_from_its_picks
    Dir.mktmpdir do |dir|
      trace = File.join(dir, "optional.itf.json")
      none, some = { "tag" => "None", "value" => { "#tup" => [] } }, { "tag" => "Some", "value" => "b1" }
      File.write(trace, JSON.generate("states" => [
        { "mbt::actionTaken" => "init", "mbt::nondetPicks" => { "b" => none, "m" => none }, "n" => { "#bigint" => "0" } },
        { "mbt::actionTaken" => "give_back", "mbt::nondetPicks" => { "b" => some, "m" => none }, "n" => { "#bigint" => "1" } }
      ]))

      assert_equal [ [ "init", {} ], [ "give_back", { "b" => "b1" } ] ], QuintDriver::Trace.steps(trace).map { [ _1.action, _1.picks ] }
    end
  end

  def test_a_system_that_follows_the_spec_replays_every_trace
    count = replay(LoansDriver.new)

    assert_equal 40, count
  end

  def test_a_system_that_breaks_the_spec_fails_the_replay_at_the_step_it_breaks
    error = assert_raises(QuintDriver::Mismatch) { replay(LoansDriver.new(BrokenLoans)) }

    assert_match(/`borrow_refused`/, error.message)
    assert_match(/outcome: trace \["Refused", "limit_reached"\], driver "Done"/, error.message)
  end

  # RSpec hides an installed gem's frames, but not those of a gem a Gemfile
  # loads from a path, and Minitest hides none, so the gem leaves its own out.
  def test_a_mismatch_s_backtrace_starts_at_the_line_that_called_replay_and_holds_no_frame_of_the_gem
    error = assert_raises(QuintDriver::Mismatch) { replay(LoansDriver.new(BrokenLoans)) }

    assert error.backtrace.first.start_with?("#{__FILE__}:#{REPLAY_LINE}:"), "the first frame calls replay"
    assert_empty error.backtrace.grep(GEM_FRAME)
  end

  def test_a_failed_replay_lists_the_steps_it_ran_and_the_call_that_rewrites_its_trace
    ran = []
    recording = Class.new(LoansDriver) { define_method(:step) { |action, picks| ran << [ action, picks ]; super(action, picks) } }
    error = assert_raises(QuintDriver::Mismatch) { replay(recording.new(BrokenLoans)) }

    assert_match(/\Aquint: after step \d+ `borrow_refused` \{.*\}, the driver differs from the trace$/, error.message.lines.first)
    refute_includes error.message, File.dirname(error.trace), "the trace directory is gone once simulate returns"
    assert_nil error.cause, "Ruby prints a cause with the path of the trace"
    steps = ran.drop(ran.rindex { _1.first == "init" }).map { |action, picks| "  #{action} {#{picks.sort.map { |k, v| "#{k.inspect} => #{v.inspect}" }.join(", ")}}" }
    assert_includes error.message, "steps:\n#{steps.join("\n")}\n"
    call = %(Quint.simulate("examples/loans/loans.qnt", traces: 40, max_steps: 20, seed: "1", step: "step", backend: "rust"))
    trace = File.basename(error.trace)
    assert_match(/\Atrace_\d+\.itf\.json\z/, trace)
    assert_equal [ "1", call ], [ error.seed, error.written_by ]
    assert_equal "trace: #{trace} of #{call}", error.message.lines.last
    again = assert_raises(QuintDriver::Mismatch) do
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 40, max_steps: 20, seed: "1") do |path|
        QuintDriver::Trace.replay(path, LoansDriver.new(BrokenLoans)) if File.basename(path) == trace
      end
    end
    assert_equal error.message[/steps:\n(  .*\n)+/], again.message[/steps:\n(  .*\n)+/]
  end

  def test_a_mismatch_reads_the_same_inside_simulate_as_after_it
    inside = nil
    outside = assert_raises(QuintDriver::Mismatch) do
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 40, max_steps: 20, seed: "1") do |path|
        QuintDriver::Trace.replay(path, LoansDriver.new(BrokenLoans))
      rescue QuintDriver::Mismatch => mismatch
        inside = mismatch.message
        raise
      end
    end

    assert_equal inside, outside.message
  end

  def test_a_mismatch_your_own_code_raises_inside_simulate_names_the_trace_it_was_yielding
    names = []
    error = assert_raises(QuintDriver::Mismatch) do
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 3, max_steps: 5, seed: "1") do |path|
        names << File.basename(path)
        raise QuintDriver::Mismatch, "quint: the ledger lost a loan" if names.size == 2
      end
    end
    line = __LINE__ - 3
    assert error.backtrace.first.start_with?("#{__FILE__}:#{line}:"), "the backtrace starts at the raise"
    assert_empty error.backtrace.grep(GEM_FRAME)

    call = %(Quint.simulate("examples/loans/loans.qnt", traces: 3, max_steps: 5, seed: "1", step: "step", backend: "rust"))
    assert_equal [ names.last, "1", call ], [ File.basename(error.trace), error.seed, error.written_by ]
    assert_equal "quint: the ledger lost a loan\ntrace: #{names.last} of #{call}", error.message
    assert_nil error.cause
  end

  def test_a_mismatch_your_own_code_raises_takes_only_its_message_and_the_gem_names_the_trace
    error = QuintDriver::Mismatch.new("quint: the ledger lost a loan")

    assert_equal [ "quint: the ledger lost a loan", nil, nil, nil ], [ error.message, error.trace, error.seed, error.written_by ]
    assert_raises(ArgumentError) { QuintDriver::Mismatch.new("quint: the ledger lost a loan", trace: "elsewhere.itf.json") }
    refute_respond_to error, :reason
  end

  def test_a_mismatch_your_own_code_raises_inside_simulate_keeps_its_class_and_cause
    lost = Class.new(QuintDriver::Mismatch)
    error = assert_raises(lost) do
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 1, max_steps: 2, seed: "1") do
        raise KeyError, "b9"
      rescue KeyError
        raise lost, "quint: the ledger lost a loan"
      end
    end

    assert_equal "b9", error.cause.message
    assert_match(/\Atrace: trace_0\.itf\.json of /, error.message.lines.last)
  end

  def test_an_error_the_driver_raises_names_its_step_the_steps_before_it_and_the_trace
    misspelled = Class.new(LoansDriver) { def step(action, picks) = action == "give_back" ? picks.fetch("book") : super }
    line = __LINE__ - 1
    error = assert_raises(QuintDriver::StepRaised) { replay(misspelled.new) }

    first, raised_in, *rest = error.message.lines
    assert_match(/\Aquint: at step (\d+) `give_back` (\{"b" => "b\d"\}), the step raised KeyError: key not found: "book"$/, first)
    assert_match(/\Araised in: test\/trace_test\.rb:#{line}:in .*fetch'\n\z/, raised_in)
    step, picks = first.match(/step (\d+) `give_back` (\{.*\}),/).captures
    steps = rest.take_while { !_1.start_with?("trace:") }
    assert_equal [ "steps:\n", "  init {}\n" ], steps.first(2)
    assert_equal [ Integer(step) + 2, "  give_back #{picks}\n" ], [ steps.size, steps.last ]
    call = %(Quint.simulate("examples/loans/loans.qnt", traces: 40, max_steps: 20, seed: "1", step: "step", backend: "rust"))
    assert_equal [ "1", call ], [ error.seed, error.written_by ]
    assert_equal "trace: #{File.basename(error.trace)} of #{call}", rest.last
    assert_equal [ KeyError, "book" ], [ error.cause.class, error.cause.key ]
    assert error.backtrace.first.start_with?("#{__FILE__}:#{line}:"), "the backtrace starts in the driver"
    assert_empty error.backtrace.grep(GEM_FRAME)
  end

  def test_an_error_the_system_raises_names_the_system_frame_it_came_from
    unfinished = Class.new(Loans) { def give_back(book) = normalize(book) }
    line = __LINE__ - 1
    error = assert_raises(QuintDriver::StepRaised) { replay(LoansDriver.new(unfinished)) }

    first, raised_in, steps = error.message.lines
    assert_match(/\Aquint: at step \d+ `give_back` \{"b" => "b\d"\}, the step raised NoMethodError: undefined method .normalize. /, first)
    assert_match(/\Araised in: test\/trace_test\.rb:#{line}:in .*give_back'\n\z/, raised_in, "the system's frame, not the driver's")
    assert_equal "steps:\n", steps
  end

  def test_an_error_raised_in_another_directory_names_its_frame_from_the_directory_the_run_started_in
    started, elsewhere = Dir.pwd, Dir.mktmpdir("elsewhere")
    moving = Class.new(LoansDriver) { define_method(:state) { Dir.chdir(elsewhere); raise "no ledger here" } }
    line = __LINE__ - 1
    error = assert_raises(QuintDriver::StepRaised) { replay(moving.new) }

    assert_match(/\Araised in: test\/trace_test\.rb:#{line}:in /, error.message.lines[1])
  ensure
    Dir.chdir(started)
    FileUtils.rm_rf(elsewhere)
  end

  def test_an_error_raised_in_rubys_library_names_the_project_frame_that_called_it
    parsing = Class.new(LoansDriver) { def step(action, picks) = action == "give_back" ? JSON.parse("{") : super }
    line = __LINE__ - 1
    error = assert_raises(QuintDriver::StepRaised) { replay(parsing.new) }

    refute_includes error.backtrace.first, __FILE__, "the error raised inside the json library"
    assert_match(/\Araised in: test\/trace_test\.rb:#{line}:in /, error.message.lines[1])
  end

  def test_an_error_with_no_frame_of_the_project_says_so
    error = assert_raises(QuintDriver::StepRaised) { replay(SimpleDelegator.new(Object.new)) }

    assert_match(/\Aquint: at step 0 `init` \{\}, the step raised NoMethodError: /, error.message)
    assert_equal "raised in: no frame of the project; every frame is in a gem, in Ruby's library, or in quint_driver\n", error.message.lines[1]
  end

  def test_an_error_raised_with_a_backtrace_of_strings_still_names_its_step
    pasted = Class.new(LoansDriver) { def state = raise(KeyError, "no holder", [ "lib/desk.rb:3:in 'Desk#holder'" ]) }
    error = assert_raises(QuintDriver::StepRaised) { replay(pasted.new) }

    assert_equal "quint: at step 0 `init` {}, the step raised KeyError: no holder\nsteps:\n", error.message.lines.first(2).join
    assert_equal [ "lib/desk.rb:3:in 'Desk#holder'" ], error.backtrace, "the error's own backtrace, though it has no Locations"
  end

  def test_an_error_the_driver_raises_reporting_its_state_names_the_step_it_followed
    stateless = Class.new(LoansDriver) { def state = raise("no state yet") }
    line = __LINE__ - 1
    error = assert_raises(QuintDriver::StepRaised) { replay(stateless.new) }

    assert_equal "quint: at step 0 `init` {}, the step raised RuntimeError: no state yet\n", error.message.lines.first
    assert_match(/\Araised in: test\/trace_test\.rb:#{line}:in .*state'\nsteps:\n  init \{\}\n\z/, error.message.lines[1, 3].join)
  end

  def test_a_mismatch_the_driver_raises_stays_a_mismatch
    checking = Class.new(LoansDriver) { def step(*) = raise(QuintDriver::Mismatch, "quint: the ledger lost a loan") }
    line = __LINE__ - 1
    error = assert_raises(QuintDriver::Mismatch) { replay(checking.new) }

    assert_equal "quint: the ledger lost a loan", error.message.lines.first.chomp
    assert error.backtrace.first.start_with?("#{__FILE__}:#{line}:"), "the backtrace starts in the driver"
    assert_empty error.backtrace.grep(GEM_FRAME)
  end

  def test_a_mismatch_on_a_trace_file_of_your_own_names_its_path
    kept = File.join(Dir.mktmpdir("kept"), "broken.itf.json")
    QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 40, max_steps: 20, seed: "1") do |path|
      QuintDriver::Trace.replay(path, LoansDriver.new(BrokenLoans))
    rescue QuintDriver::Mismatch
      FileUtils.cp(path, kept) unless File.exist?(kept)
    end

    error = assert_raises(QuintDriver::Mismatch) { QuintDriver::Trace.replay(kept, LoansDriver.new(BrokenLoans)) }
    assert_equal [ kept, nil, nil ], [ error.trace, error.seed, error.written_by ]
    assert_equal "trace: #{kept}", error.message.lines.last
  ensure
    FileUtils.rm_rf(File.dirname(kept))
  end

  def test_a_mismatch_prints_a_record_with_its_keys_in_one_order_on_both_sides
    spec = QuintDriver::Spec.new(File.expand_path("operators.qnt", __dir__), main: "operators")
    reversed = Class.new do
      define_method(:initialize) { @model = spec.model }
      define_method(:step) { |action, picks| @model.step(action, picks) }
      define_method(:state) { { "count" => @model.state["count"].then { { "value" => _1["value"] + 1, "full" => _1["full"] } } } }
    end
    error = assert_raises(QuintDriver::Mismatch) do
      QuintDriver::Quint.simulate(File.expand_path("operators.qnt", __dir__), main: "operators", traces: 1, max_steps: 1, seed: "1") do |path|
        QuintDriver::Trace.replay(path, reversed.new)
      end
    end

    assert_includes error.message, %(  count: trace {"full" => false, "value" => 0}, driver {"full" => false, "value" => 1}\n)
  end

  def test_a_driver_is_held_only_to_the_variables_it_reports
    holder_only = Class.new(LoansDriver) { def state = super.slice("holder") }

    assert_equal 40, replay(holder_only.new)
  end

  # A value the spec derives from its variables, such as a total, is in no
  # trace state, so only an observed definition holds the system's copy of it.
  class CountingDriver < LoansDriver
    def initialize(system = Loans, &lent) = (super(system); @lent = lent || ->(count) { count == 2 })
    def state = super.then { _1.merge("two_on_loan" => @lent.(_1["holder"].count { |_, holder| holder != "" })) }
  end

  def test_a_driver_is_held_to_each_definition_it_observes
    assert_equal 40, replay(CountingDriver.new, spec: LoansDriver.spec, observe: %w[two_on_loan])
    assert_equal 40, replay(CountingDriver.new, spec: LoansDriver.spec, observe: %i[two_on_loan]), "a definition named by a symbol"
  end

  def test_a_wrong_derived_value_fails_the_step_that_shows_it
    miscounting = CountingDriver.new { |count| count >= 1 }

    error = assert_raises(QuintDriver::Mismatch) { replay(miscounting, spec: LoansDriver.spec, observe: %w[two_on_loan]) }
    assert_match(/\Aquint: after step \d+ `borrow` \{.*\}, the driver differs from the trace\n  two_on_loan: trace false, driver true\nsteps:\n  init \{\}\n/, error.message)
  end

  def test_an_observed_definition_the_driver_does_not_report_fails
    error = assert_raises(QuintDriver::Mismatch) { replay(LoansDriver.new, spec: LoansDriver.spec, observe: %w[two_on_loan]) }

    assert_match(/\Aquint: after step 0 `init` \{\}, the driver differs from the trace\n  two_on_loan: trace false, driver nil\n/, error.message)
  end

  def test_observe_names_only_definitions_without_parameters
    [ "borrow", "onLoan", "missing" ].each do |name|
      error = assert_raises(ArgumentError) { replay(CountingDriver.new, spec: LoansDriver.spec, observe: [ name ]) }
      assert_equal "quint: observe names #{name}, which is no definition without parameters of loans; " \
                   "it has BOOKS, MEMBERS, NOBODY, nothing_on_loan, one_book_each, two_on_loan", error.message
    end
    error = assert_raises(ArgumentError) { replay(CountingDriver.new, observe: %w[two_on_loan one_book_each]) }
    assert_equal "quint: observe needs spec:, the Spec that evaluates two_on_loan, one_book_each", error.message
  end

  def test_a_step_that_names_no_action_is_refused
    spec = QuintDriver::Spec.new(ANONYMOUS, main: "anonymous")
    silent = Class.new { def step(*) = nil; def state = {} }.new # reports no variable, so only the refusal fails

    listed = assert_raises(QuintDriver::Unsupported) { spec.rules("step") }
    assert_equal "quint: step assigns n' in an arm that names no action; name every action in step", listed.message
    error = assert_raises(QuintDriver::Unsupported) do
      QuintDriver::Quint.simulate(ANONYMOUS, traces: 1, max_steps: 2, seed: "1") do |path|
        QuintDriver::Trace.replay(path, silent)
      end
    end
    assert_match(/anonymous action/, error.message)
  end

  def test_an_arm_that_names_no_action_is_reported_in_the_action_that_holds_it
    error = assert_raises(QuintDriver::Unsupported) { QuintDriver::Spec.new(ANONYMOUS, main: "nested").rules("step") }

    assert_equal "quint: counting assigns n' in an arm that names no action; name every action in step", error.message
  end

  def test_an_arm_that_is_neither_a_call_nor_an_assignment_is_reported_by_its_operator
    error = assert_raises(QuintDriver::Unsupported) { QuintDriver::Spec.new(ANONYMOUS, main: "conjunction").rules("step") }

    assert_equal "quint: step holds actionAll in an arm that names no action; name every action in step", error.message
  end

  def test_a_step_of_one_all_around_its_picks_lists_the_actions_of_the_any_inside
    spec = QuintDriver::Spec.new(ANONYMOUS, main: "wrapped")
    rules = spec.rules("step")

    assert_equal [ [ "add", %w[x] ], [ "sub", %w[x] ] ], rules.map { [ _1.action, _1.domains.keys ] }
    steps = 0
    QuintDriver::Quint.simulate(ANONYMOUS, main: "wrapped", traces: 5, max_steps: 4, seed: "1") do |path|
      steps += QuintDriver::Trace.replay(path, spec.model).size
    end
    assert_equal 25, steps
  end

  def test_a_step_that_is_no_action_of_the_module_lists_the_actions_it_has
    error = assert_raises(ArgumentError) { QuintDriver::Spec.new(ANONYMOUS, main: "nested").rules("steps") }

    assert_equal "quint: no action is named steps; the module has counting, init, step", error.message
  end

  def test_a_replay_returns_the_steps_it_ran_so_a_caller_can_count_what_the_traces_reached
    reached = Hash.new(0)
    QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 40, max_steps: 20, seed: "1") do |path|
      steps = QuintDriver::Trace.replay(path, LoansDriver.new)
      assert_equal QuintDriver::Trace.steps(path).map(&:to_a), steps.map(&:to_a)
      steps.each { reached[_1.action] += 1 }
    end

    assert_equal %w[borrow borrow_refused give_back give_back_refused init], reached.keys.sort
    assert_equal 40, reached["init"]
  end

  def test_a_replay_prints_each_step_before_the_driver_runs_it
    log = StringIO.new
    error = assert_raises(QuintDriver::Mismatch) do
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 40, max_steps: 20, seed: "1") do |path|
        log.reopen(+"")
        QuintDriver::Trace.replay(path, LoansDriver.new(BrokenLoans), log:)
      end
    end

    ran = error.message[/^steps:\n((?:  .*\n)+)/, 1].lines.map(&:strip)
    assert_equal ran.each_with_index.map { |move, index| "step #{index} #{move}\n" }.join, log.string
  end

  def test_a_named_run_replays_the_action_its_spec_records_and_holds_the_driver_to_the_state_it_names
    driver = RecordedDriver.new
    QuintDriver::Quint.test(RECORDED, "lendTest", seed: "1") do |path|
      QuintDriver::Trace.replay(path, driver, state: %w[s books], action: %w[s taken])
    end

    assert_equal [ [ "Init", {} ], [ "Borrow", { "m" => "m1", "b" => "b1" } ], [ "Borrow", { "m" => "m2", "b" => "b2" } ], [ "GiveBack", { "b" => "b1" } ] ],
                 driver.ran
  end

  def test_a_named_run_that_breaks_the_system_names_the_state_it_differs_in_and_the_call_that_writes_it
    error = assert_raises(QuintDriver::Mismatch) do
      QuintDriver::Quint.test(RECORDED, "lendTest", seed: "1") do |path|
        QuintDriver::Trace.replay(path, RecordedDriver.new(KeepingLoans), state: %w[s books], action: %w[s taken])
      end
    end

    call = %(Quint.test("test/recorded.qnt", "lendTest", seed: "1"))
    assert_equal <<~MESSAGE.chomp, error.message
      quint: after step 3 `GiveBack` {"b" => "b1"}, the driver differs from the trace
        b1: trace "", driver "m1"
      steps:
        Init {}
        Borrow {"b" => "b1", "m" => "m1"}
        Borrow {"b" => "b2", "m" => "m2"}
        GiveBack {"b" => "b1"}
      trace: test_0.itf.json of #{call}
    MESSAGE
    assert_equal [ "1", call ], [ error.seed, error.written_by ]
  end

  def test_a_trace_with_no_action_taken_asks_for_the_variable_that_records_it
    error = assert_raises(QuintDriver::Unsupported) do
      QuintDriver::Quint.test(RECORDED, "lendTest", seed: "1") { QuintDriver::Trace.replay(_1, RecordedDriver.new) }
    end

    assert_equal "quint: state 0 of the trace names no action taken; quint test writes no mbt::actionTaken, " \
                 "so pass action: the path to a variable that records it", error.message
  end

  def test_a_path_the_trace_does_not_have_names_where_it_stops
    error = assert_raises(QuintDriver::Unsupported) do
      QuintDriver::Quint.test(RECORDED, "lendTest", seed: "1") do |path|
        QuintDriver::Trace.replay(path, RecordedDriver.new, state: %w[s shelf], action: %w[s taken])
      end
    end

    assert_equal "quint: state 0 of the trace has no s.shelf; s has books, taken", error.message
  end

  def test_a_state_path_that_names_no_record_or_map_says_what_it_names
    error = assert_raises(QuintDriver::Unsupported) do
      QuintDriver::Quint.test(RECORDED, "lendTest", seed: "1") do |path|
        QuintDriver::Trace.replay(path, RecordedDriver.new, state: %w[s taken], action: %w[s taken])
      end
    end

    assert_equal "quint: state 0 of the trace has s.taken = \"Init\", which is no record or map; " \
                 "pass state: the path to the record or map the driver reports", error.message
  end

  private
    def replay(driver, **observing)
      count = 0
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 40, max_steps: 20, seed: "1") do |path|
        QuintDriver::Trace.replay(path, driver, **observing)
        count += 1
      end
      count
    end
    REPLAY_LINE = __LINE__ - 5
end
