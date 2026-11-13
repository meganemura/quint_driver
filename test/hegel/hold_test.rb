require_relative "../test_helper"
require "quint_driver/hegel"
require "stringio"
require_relative "../../examples/shelf/shelf"

class HegelHoldTest < Minitest::Test
  # Hegel picks when each reservation reads and writes, and shrinks the lost
  # update to two reads before two writes.
  def test_hegel_shrinks_a_lost_update_to_two_reads_before_two_writes
    spec = QuintDriver::Spec.new(ShelfDriver::SPEC, main: "shelf")
    machine = QuintDriver.machine(spec, driver: -> { ShelfDriver.new }, invariants: %w[every_reservation_takes_one])

    error = assert_raises(QuintDriver::Violated) do
      Hegel.test(test_cases: 100, seed: 1, output: StringIO.new) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end
    assert_equal [ "init", "load", "load", "save", "save" ], error.message[/steps:\n(.*?)\nstate:/m, 1].lines.map { _1.split.first }
  end
end
