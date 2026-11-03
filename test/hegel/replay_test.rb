require_relative "../test_helper"
require "quint_driver/hegel"
require "fileutils"
require "tmpdir"

class ReplayPropertyTest < Minitest::Test
  include Hegel::Syntax::Methods
  SETTINGS = { test_cases: 100, seed: 1, suppress_health_check: %i[filter_too_much too_slow] }.freeze

  # Wherever in a trace the driver raises, in a step or in its state, the
  # failure names that step and lists the trace's steps up to it.
  def test_a_driver_error_names_the_step_it_raised_in_and_the_steps_before_it
    dir = Dir.mktmpdir("replay")
    trace = File.join(dir, "kept.itf.json")
    QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 1, max_steps: 20, seed: "1") { FileUtils.cp(_1, trace) }
    steps = QuintDriver::Trace.steps(trace)

    Hegel.test(**SETTINGS) do |tc|
      at = tc.draw(integers(min_value: 0, max_value: steps.size - 1), label: "at")
      part = tc.draw(sampled_from(%i[step state]), label: "part")
      calls = 0
      failing = Class.new(LoansDriver) do
        define_method(part) do |*args|
          raise IndexError, "call #{calls}" if calls == at
          calls += 1
          super(*args)
        end
      end

      error = assert_raises(QuintDriver::DriverFailed) { QuintDriver::Trace.replay(trace, failing.new) }
      first, *rest = error.message.lines
      assert first.start_with?("quint: at step #{at} `#{steps[at].action}` "), first
      assert first.end_with?("the step raised IndexError: call #{at}\n"), first
      assert_equal steps.first(at + 1).map(&:action), rest[1..at + 1].map { _1.split.first }
      assert_equal "trace: #{trace}", rest.last
      assert_equal IndexError, error.cause.class
    end
  ensure
    FileUtils.rm_rf(dir)
  end
end
