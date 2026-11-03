require_relative "../test_helper"
require "quint_driver/hegel"
require "fileutils"
require "tmpdir"

class ReplayPropertyTest < Minitest::Test
  include Hegel::Syntax::Methods
  SETTINGS = { test_cases: 100, seed: 1, suppress_health_check: %i[filter_too_much too_slow] }.freeze

  # Wherever in a trace a step raises, in the driver's step, in its state,
  # or in the system beneath it, the failure names that step and lists the
  # trace's steps up to it, and names the system's frame only when the
  # system raised.
  def test_a_step_error_names_the_step_it_raised_in_and_the_steps_before_it
    dir = Dir.mktmpdir("replay")
    trace = File.join(dir, "kept.itf.json")
    QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 1, max_steps: 20, seed: "1") { FileUtils.cp(_1, trace) }
    steps = QuintDriver::Trace.steps(trace)

    Hegel.test(**SETTINGS) do |tc|
      at = tc.draw(integers(min_value: 0, max_value: steps.size - 1), label: "at")
      part = tc.draw(sampled_from(%i[step state system]), label: "part")
      calls = 0
      raise_at = lambda do |count|
        raise IndexError, "call #{calls}" if calls == count
        calls += 1
      end
      driver = if part == :system
        # The driver's state reads every book's holder once per step.
        holders = LoansDriver::BOOKS.size
        LoansDriver.new(Class.new(Loans) { define_method(:holder) { |book| raise_at.(at * holders); super(book) } })
      else
        Class.new(LoansDriver) { define_method(part) { |*args| raise_at.(at); super(*args) } }.new
      end

      error = assert_raises(QuintDriver::DriverFailed) { QuintDriver::Trace.replay(trace, driver) }
      first, *rest = error.message.lines
      raised_in = rest.first.start_with?("raised in: ") ? rest.shift : nil
      assert first.start_with?("quint: at step #{at} `#{steps[at].action}` "), first
      assert_match(/the step raised IndexError: call \d+\n\z/, first)
      assert_equal part == :system, raised_in&.start_with?("raised in: #{__FILE__}:") || false, "only the system's frame is named"
      assert_equal steps.first(at + 1).map(&:action), rest[1..at + 1].map { _1.split.first }
      assert_equal "trace: #{trace}", rest.last
      assert_equal IndexError, error.cause.class
    end
  ensure
    FileUtils.rm_rf(dir)
  end
end
