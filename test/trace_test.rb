require_relative "test_helper"
require "fileutils"
require "stringio"

class TraceTest < Minitest::Test
  ANONYMOUS = File.expand_path("anonymous.qnt", __dir__)

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

  def test_a_system_that_follows_the_spec_replays_every_trace
    count = replay(LoansDriver.new)

    assert_equal 40, count
  end

  def test_a_system_that_breaks_the_spec_fails_the_replay_at_the_step_it_breaks
    error = assert_raises(QuintDriver::Mismatch) { replay(LoansDriver.new(BrokenLoans)) }

    assert_match(/`borrow_refused`/, error.message)
    assert_match(/outcome: trace \["Refused", "limit_reached"\], driver "Done"/, error.message)
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
    call = %(Quint.simulate(#{LoansDriver::SPEC.inspect}, traces: 40, max_steps: 20, seed: "1", step: "step", backend: "rust"))
    trace = File.basename(error.trace)
    assert_match(/\Atrace_\d+\.itf\.json\z/, trace)
    assert_equal [ "1", call ], [ error.seed, error.simulate ]
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

    call = %(Quint.simulate(#{LoansDriver::SPEC.inspect}, traces: 3, max_steps: 5, seed: "1", step: "step", backend: "rust"))
    assert_equal [ names.last, "1", call ], [ File.basename(error.trace), error.seed, error.simulate ]
    assert_equal "quint: the ledger lost a loan\ntrace: #{names.last} of #{call}", error.message
    assert_nil error.cause
  end

  def test_a_mismatch_your_own_code_raises_takes_only_its_message_and_the_gem_names_the_trace
    error = QuintDriver::Mismatch.new("quint: the ledger lost a loan")

    assert_equal [ "quint: the ledger lost a loan", nil, nil, nil ], [ error.message, error.trace, error.seed, error.simulate ]
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
    error = assert_raises(QuintDriver::DriverFailed) { replay(misspelled.new) }

    first, *rest = error.message.lines
    assert_match(/\Aquint: at step (\d+) `give_back` (\{"b" => "b\d"\}), the driver raised KeyError: key not found: "book"$/, first)
    step, picks = first.match(/step (\d+) `give_back` (\{.*\}),/).captures
    steps = rest.take_while { !_1.start_with?("trace:") }
    assert_equal [ "steps:\n", "  init {}\n" ], steps.first(2)
    assert_equal [ Integer(step) + 2, "  give_back #{picks}\n" ], [ steps.size, steps.last ]
    call = %(Quint.simulate(#{LoansDriver::SPEC.inspect}, traces: 40, max_steps: 20, seed: "1", step: "step", backend: "rust"))
    assert_equal [ "1", call ], [ error.seed, error.simulate ]
    assert_equal "trace: #{File.basename(error.trace)} of #{call}", rest.last
    assert_equal [ KeyError, "book" ], [ error.cause.class, error.cause.key ]
    assert error.backtrace.first.start_with?("#{__FILE__}:#{line}:"), "the backtrace starts in the driver"
  end

  def test_an_error_the_driver_raises_reporting_its_state_names_the_step_it_followed
    stateless = Class.new(LoansDriver) { def state = raise("no state yet") }
    error = assert_raises(QuintDriver::DriverFailed) { replay(stateless.new) }

    assert_equal "quint: at step 0 `init` {}, the driver raised RuntimeError: no state yet\nsteps:\n  init {}\n", error.message.lines.first(3).join
  end

  def test_a_mismatch_the_driver_raises_stays_a_mismatch
    checking = Class.new(LoansDriver) { def step(*) = raise(QuintDriver::Mismatch, "quint: the ledger lost a loan") }
    error = assert_raises(QuintDriver::Mismatch) { replay(checking.new) }

    assert_equal "quint: the ledger lost a loan", error.message.lines.first.chomp
  end

  def test_a_mismatch_on_a_trace_file_of_your_own_names_its_path
    kept = File.join(Dir.mktmpdir("kept"), "broken.itf.json")
    QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 40, max_steps: 20, seed: "1") do |path|
      QuintDriver::Trace.replay(path, LoansDriver.new(BrokenLoans))
    rescue QuintDriver::Mismatch
      FileUtils.cp(path, kept) unless File.exist?(kept)
    end

    error = assert_raises(QuintDriver::Mismatch) { QuintDriver::Trace.replay(kept, LoansDriver.new(BrokenLoans)) }
    assert_equal [ kept, nil, nil ], [ error.trace, error.seed, error.simulate ]
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

  def test_a_step_that_is_no_action_of_the_module_lists_the_actions_it_has
    error = assert_raises(ArgumentError) { QuintDriver::Spec.new(ANONYMOUS, main: "nested").rules("steps") }

    assert_equal "quint: no action is named steps; the module has counting, init, step", error.message
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

  private
    def replay(driver)
      count = 0
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 40, max_steps: 20, seed: "1") do |path|
        QuintDriver::Trace.replay(path, driver)
        count += 1
      end
      count
    end
end
