# QuintDriver.replay_steps runs the steps a failure printed on a driver and on
# the spec's model, so a failure found by a trace or by Hegel is pinned as one
# example that needs neither.
require_relative "test_helper"

class StepsTest < Minitest::Test
  UNLIMITED = QuintDriver::Spec.new(File.expand_path("unlimited.qnt", __dir__), main: "unlimited")

  # As a Violated of unlimited.qnt printed them, the trace line left out.
  PRINTED = <<~STEPS
    steps:
      init {}
      borrow {"b" => "b1", "m" => "m2"}
      borrow {"b" => "b3", "m" => "m2"}
  STEPS

  def test_pasted_steps_raise_the_violated_they_were_printed_with
    error = assert_raises(QuintDriver::Violated) do
      QuintDriver.replay_steps(UNLIMITED, LoansDriver.new(BrokenLoans), PRINTED, invariants: %w[one_book_each])
    end
    assert_equal <<~MESSAGE.chomp, error.message
      quint: the system agreed with the spec at every step, and the expectation `one_book_each` does not hold after step 2 `borrow` {"b" => "b3", "m" => "m2"}
      #{PRINTED.chomp}
      state:
        holder: {"b1" => "m2", "b2" => "", "b3" => "m2"}
        outcome: "Done"
    MESSAGE
    assert error.backtrace.first.start_with?(__FILE__), "the test's own line leads"
  end

  def test_steps_that_agree_and_keep_every_expectation_return_the_steps_ran
    ran = QuintDriver.replay_steps(LoansDriver.spec, LoansDriver.new, [ [ "borrow", { "m" => "m1", "b" => "b1" } ], [ :give_back, { b: "b1" } ] ],
                                   invariants: %w[one_book_each])

    assert_equal [ [ "init", {} ], [ "borrow", { "m" => "m1", "b" => "b1" } ], [ "give_back", { "b" => "b1" } ] ], ran
  end

  def test_a_driver_that_disagrees_raises_a_mismatch_at_the_step
    steps = <<~STEPS
      borrow {"b" => "b1", "m" => "m1"}
      borrow_refused {"b" => "b2", "m" => "m1"}
    STEPS
    error = assert_raises(QuintDriver::Mismatch) { QuintDriver.replay_steps(LoansDriver.spec, LoansDriver.new(BrokenLoans), steps) }

    assert_match(/after step 2 `borrow_refused` \{"b" => "b2", "m" => "m1"\}, the driver differs from the model/, error.message)
    assert_match(/outcome: model \["Refused", "limit_reached"\], driver "Done"/, error.message)
  end

  def test_a_step_the_spec_does_not_allow_raises_a_mismatch_that_names_it
    steps = [ [ "borrow", { "m" => "m1", "b" => "b1" } ], [ "borrow", { "m" => "m2", "b" => "b1" } ] ]
    error = assert_raises(QuintDriver::Mismatch) { QuintDriver.replay_steps(LoansDriver.spec, LoansDriver.new, steps) }

    assert_equal <<~MESSAGE.chomp, error.message
      quint: the model refused borrow {"b" => "b1", "m" => "m2"}, at step 2 `borrow` {"b" => "b1", "m" => "m2"}
      steps:
        init {}
        borrow {"b" => "b1", "m" => "m1"}
        borrow {"b" => "b1", "m" => "m2"}
    MESSAGE
  end

  def test_a_line_whose_picks_are_no_hash_is_refused
    error = assert_raises(ArgumentError) { QuintDriver.replay_steps(LoansDriver.spec, LoansDriver.new, "borrow b1\n") }

    assert_match(/replay_steps cannot read b1/, error.message)
  end

  def test_the_steps_read_back_every_value_a_failure_prints
    steps =QuintDriver.const_get(:Steps).parse(<<~STEPS)
      init {}
      put {"at" => {1, 2}, "by" => {"x" => [-3, true, nil]}, "s" => "a \\"b\\" ,}"}
    STEPS

    assert_equal [ [ "init", {} ], [ "put", { "at" => Set[1, 2], "by" => { "x" => [ -3, true, nil ] }, "s" => 'a "b" ,}' } ] ], steps
  end
end
