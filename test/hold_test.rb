require_relative "test_helper"
require_relative "../examples/shelf/shelf"

class HoldTest < Minitest::Test
  def test_a_held_call_stops_at_its_pause_and_goes_on_when_finished
    hold = QuintDriver::Hold.new
    log = []

    assert_equal :read, hold.start("r1") { log << :before; hold.pause(:read); log << :after; :written }
    assert_equal [ :before ], log
    assert_equal [ "r1" ], hold.held
    assert_equal :written, hold.finish("r1")
    assert_equal [ :before, :after ], log
    refute hold.held?("r1")
  end

  def test_a_call_that_never_pauses_runs_to_its_end_at_start
    hold = QuintDriver::Hold.new

    assert_equal :done, hold.start("r1") { :done }
    assert_empty hold.held
  end

  def test_a_pause_outside_a_held_call_does_nothing
    hold = QuintDriver::Hold.new

    assert_nil hold.pause(:anything)
    assert_equal :inner, hold.start("r1") { QuintDriver::Hold.new.pause(:other); :inner }
  end

  # Enumerator#next runs its block in a Fiber of its own, so a pause there
  # cannot stop the held call. It raises, since a call that ran through
  # would agree with the spec for the wrong reason.
  def test_a_pause_in_a_fiber_inside_the_held_call_raises
    hold = QuintDriver::Hold.new

    error = assert_raises(ArgumentError) { hold.start("r1") { Enumerator.new { |y| hold.pause(:read); y << 1 }.next } }
    assert_equal 'quint: "r1" paused in a Fiber of its own, such as one Enumerator#next runs; pause where the held call runs, outside that Fiber', error.message
    assert_empty hold.held
  end

  def test_a_held_call_that_yields_its_fiber_itself_raises
    hold = QuintDriver::Hold.new

    error = assert_raises(ArgumentError) { hold.start("r1") { Fiber.yield(:raw) } }
    assert_equal 'quint: "r1" called Fiber.yield itself; a held call stops only at pause', error.message
    assert_empty hold.held
  end

  def test_an_error_before_the_pause_comes_out_of_start_and_frees_the_name
    hold = QuintDriver::Hold.new

    assert_raises(RuntimeError) { hold.start("r1") { raise "no row" } }
    assert_empty hold.held
    assert_equal :again, hold.start("r1") { :again }
  end

  def test_finish_runs_through_every_later_pause
    hold = QuintDriver::Hold.new
    hold.start("r1") { hold.pause(1); hold.pause(2); :end }

    assert_equal :end, hold.finish("r1")
  end

  def test_an_error_in_a_held_call_comes_out_of_finish_and_frees_the_name
    hold = QuintDriver::Hold.new
    hold.start("r1") { hold.pause; raise "saved nothing" }

    assert_equal "saved nothing", assert_raises(RuntimeError) { hold.finish("r1") }.message
    refute hold.held?("r1")
  end

  def test_a_name_is_held_once_and_finished_once
    hold = QuintDriver::Hold.new
    hold.start("r1") { hold.pause }

    assert_equal 'quint: "r1" is already held; finish it first', assert_raises(ArgumentError) { hold.start("r1") { nil } }.message
    hold.finish("r1")
    assert_equal 'quint: nothing is held as "r1"; held: []', assert_raises(ArgumentError) { hold.finish("r1") }.message
  end

  # The shelf follows the spec at every step, and a trace where a second
  # reservation reads between the first one's read and write breaks the
  # owner's expectation: the lost update is a Violated, not a Mismatch.
  def test_a_reservation_held_between_its_read_and_its_write_loses_an_update
    spec = QuintDriver::Spec.new(ShelfDriver::SPEC, main: "shelf")
    expectation = %w[every_reservation_takes_one]
    violated = []

    simulation = QuintDriver::Quint.simulate(ShelfDriver::SPEC, traces: 50, max_steps: 6, seed: "1", violate: expectation.first) do |path|
      QuintDriver::Trace.replay(path, ShelfDriver.new)
      violated << assert_raises(QuintDriver::Violated) { QuintDriver::Trace.replay(path, ShelfDriver.new, spec:, invariants: expectation) }
    end

    refute_empty violated
    assert_equal simulation.violated, violated.size
    assert_empty simulation.never
    assert_match(/load .*\n.*load .*\n.*save /, violated.min_by { _1.message.length }.message)
  end

  def test_the_skill_quotes_the_shelf_and_the_violated_it_raises
    section = File.read(File.expand_path("../skills/quint_driver/SKILL.md", __dir__))[/^### A request another one comes between\n(.*?)(?=^## )/m, 1]
    shelf = %w[shelf.qnt shelf.rb].sum("") { File.read(File.expand_path("../examples/shelf/#{_1}", __dir__)) }
    blocks = section.scan(/^```(\w+)\n(.*?)^```$/m)

    blocks.reject { |kind, _| kind == "text" }.each { |_, body| assert_includes shelf, body }
    assert_includes section, "```text\n#{lost_update.message}\n```"
  end

  def test_the_pasted_steps_of_a_lost_update_raise_it_again
    assert_equal <<~TEXT.chomp, lost_update.message
      quint: the system agreed with the spec at every step, and the expectation `every_reservation_takes_one` does not hold after step 4 `save` {"r" => "r2"}
      steps:
        init {}
        load {"r" => "r1"}
        load {"r" => "r2"}
        save {"r" => "r1"}
        save {"r" => "r2"}
      state:
        loaded: {}
        reserved: 2
        stock: 2
    TEXT
  end

  private
    def lost_update
      spec = QuintDriver::Spec.new(ShelfDriver::SPEC, main: "shelf")
      assert_raises(QuintDriver::Violated) do
        QuintDriver.replay_steps(spec, ShelfDriver.new, <<~STEPS, invariants: %w[every_reservation_takes_one])
          load {"r" => "r1"}
          load {"r" => "r2"}
          save {"r" => "r1"}
          save {"r" => "r2"}
        STEPS
      end
    end
end
