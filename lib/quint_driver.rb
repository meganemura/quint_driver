require "set"

# Tests a Ruby system against a Quint spec. Two ways share one driver: replay
# the traces `quint run --mbt` writes (QuintDriver::Trace.replay), or let Hegel
# choose the steps from the spec's actions (QuintDriver.machine, which
# `require "quint_driver/hegel"` adds). A driver answers #step(action, picks)
# by running that command on the system, and #state with the spec's variables
# as plain Ruby values.
#
# Plain values: a Quint set is a Set, a map a Hash, a tuple an Array, a record
# a Hash with string keys, a sum type its tag, or [tag, value] when it carries
# one.
module QuintDriver
  # The system and the spec disagree.
  class Mismatch < StandardError; end

  # The quint command failed. The message holds its output.
  class QuintFailed < StandardError; end

  # The spec uses an operator the model does not evaluate, or a shape no
  # driver can run, such as a step arm that names no action.
  class Unsupported < StandardError; end

  # Raises Mismatch naming each variable where +actual+ differs from
  # +expected+. Compares only the variables +actual+ reports.
  def self.compare!(after, expected, actual, by:)
    expected = expected.slice(*actual.keys)
    return if expected == actual

    diff = actual.keys.reject { expected[_1] == actual[_1] }
                 .map { "  #{_1}: #{by} #{show(expected[_1])}, driver #{show(actual[_1])}" }
    raise Mismatch, "quint: after #{after}, the driver differs from the #{by}\n#{diff.join("\n")}"
  end

  def self.show(value) = value.is_a?(Set) ? "{#{value.map { show(_1) }.sort.join(', ')}}" : value.inspect
end

require_relative "quint_driver/version"
require_relative "quint_driver/quint"
require_relative "quint_driver/trace"
require_relative "quint_driver/spec"
require_relative "quint_driver/model"
