require_relative "test_helper"

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
      "#meta" => { "index" => 0 }
    }
    plain = {
      "set" => Set["a", "b"], "map" => { "k" => 7 }, "tuple" => [ "a", 1 ], "bare" => "Done",
      "carrying" => [ "Refused", "on_loan" ], "none" => nil, "some" => "b1"
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

  def test_a_driver_is_held_only_to_the_variables_it_reports
    holder_only = Class.new(LoansDriver) { def state = super.slice("holder") }

    assert_equal 40, replay(holder_only.new)
  end

  def test_a_step_that_names_no_action_is_refused
    spec = QuintDriver::Spec.new(ANONYMOUS, main: "anonymous")

    assert_raises(RuntimeError) { spec.rules("step") }
    error = assert_raises(RuntimeError) do
      QuintDriver::Quint.simulate(ANONYMOUS, traces: 1, max_steps: 2, seed: "1") do |path|
        QuintDriver::Trace.replay(path, QuintDriver::Model.new(spec.declarations, []))
      end
    end
    assert_match(/anonymous action/, error.message)
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
