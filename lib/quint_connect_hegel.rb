require "set"

# Tests a Ruby system against a Quint spec. Two ways share one driver: replay
# the traces `quint run --mbt` writes (QuintConnectHegel::Trace.replay), or let Hegel
# choose the steps from the spec's actions (QuintConnectHegel.machine). A driver
# answers #step(action, picks) by running that command on the system, and
# #state with the spec's variables as plain Ruby values.
#
# Plain values: a Quint set is a Set, a map a Hash, a tuple an Array, a record
# a Hash with string keys, a sum type its tag, or [tag, value] when it carries
# one.
module QuintConnectHegel
  class Mismatch < StandardError; end

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

require_relative "quint_connect_hegel/version"
require_relative "quint_connect_hegel/quint"
require_relative "quint_connect_hegel/trace"
require_relative "quint_connect_hegel/spec"
require_relative "quint_connect_hegel/model"
require_relative "quint_connect_hegel/machine"
