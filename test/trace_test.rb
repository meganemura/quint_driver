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
    steps = ran.drop(ran.rindex { _1.first == "init" }).map { |action, picks| "  #{action} #{picks.inspect}" }
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

  def test_a_driver_is_held_only_to_the_variables_it_reports
    holder_only = Class.new(LoansDriver) { def state = super.slice("holder") }

    assert_equal 40, replay(holder_only.new)
  end

  def test_a_step_that_names_no_action_is_refused
    spec = QuintDriver::Spec.new(ANONYMOUS, main: "anonymous")
    silent = Class.new { def step(*) = nil; def state = {} }.new # reports no variable, so only the refusal fails

    assert_raises(QuintDriver::Unsupported) { spec.rules("step") }
    error = assert_raises(QuintDriver::Unsupported) do
      QuintDriver::Quint.simulate(ANONYMOUS, traces: 1, max_steps: 2, seed: "1") do |path|
        QuintDriver::Trace.replay(path, silent)
      end
    end
    assert_match(/anonymous action/, error.message)
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
