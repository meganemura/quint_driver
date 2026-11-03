require "set"

# Tests a Ruby system against a Quint spec. Two ways share one driver: replay
# the traces `quint run --mbt` writes (QuintDriver::Trace.replay), or let Hegel
# choose the steps from the spec's actions (QuintDriver.machine, which
# `require "quint_driver/hegel"` adds). A driver answers #step(action, picks)
# by running that command on the system, and #state with the spec's variables
# as plain Ruby values.
#
# Plain values: a Quint set is a Set, a map a Hash, a tuple or a list an
# Array, a record a Hash with string keys, a sum type its tag, or
# [tag, value] when it carries one.
module QuintDriver
  # The system and the spec disagree. On a replay, +trace+ is the path of the
  # trace. Under Quint.simulate that file is gone once the block returns, so
  # +seed+ and +simulate+ hold the seed and the call that write it again, and
  # the message names the trace by those instead of by its path.
  #
  # A driver or a check of the caller's own raises one with a message alone,
  # as `raise QuintDriver::Mismatch, "..."`; replay and simulate fill in the
  # trace, so a caller cannot name a trace that disagrees with the one that ran.
  class Mismatch < StandardError
    attr_reader :trace, :seed, :simulate

    def to_s
      return super unless trace

      "#{super}\ntrace: #{simulate ? "#{File.basename(trace)} of #{simulate}" : trace}"
    end

    private
      def name_trace(trace, seed: nil, simulate: nil) = (@trace, @seed, @simulate = trace, seed, simulate)
  end

  # The quint command failed. The message holds its output.
  class QuintFailed < StandardError; end

  # The spec uses an operator the model does not evaluate, or a shape no
  # driver can run, such as a step arm that names no action.
  class Unsupported < StandardError; end

  # The one check Trace.replay and the Hegel machine share. It is private, so
  # the gem's API stays the driver protocol and the errors.
  module Agreement
    # Raises Mismatch naming each variable where +actual+ differs from
    # +expected+, and the [action, picks] +steps+ the driver ran from init, so
    # the failure can be run again without the trace file. Compares only the
    # variables +actual+ reports.
    def self.check!(after, expected, actual, by:, steps:)
      expected = expected.slice(*actual.keys)
      return if expected == actual

      diff = actual.keys.reject { expected[_1] == actual[_1] }
                   .map { "  #{_1}: #{by} #{show(expected[_1])}, driver #{show(actual[_1])}" }
      ran = steps.map { |action, picks| "  #{action} #{show(picks)}" }
      raise Mismatch, "quint: after #{after}, the driver differs from the #{by}\n#{diff.join("\n")}\nsteps:\n#{ran.join("\n")}"
    end

    # A plain value as a failure prints it: a set's elements and a hash's
    # keys sorted, so the spec's side and the driver's side, and a replay and
    # the machine, print the same value the same way on every Ruby.
    def self.show(value)
      case value
      when Set then "{#{value.map { show(_1) }.sort.join(', ')}}"
      when Hash then "{#{value.map { |k, v| [ show(k), show(v) ] }.sort.map { "#{_1} => #{_2}" }.join(', ')}}"
      when Array then "[#{value.map { show(_1) }.join(', ')}]"
      else value.inspect
      end
    end
  end
  private_constant :Agreement
end

require_relative "quint_driver/version"
require_relative "quint_driver/quint"
require_relative "quint_driver/trace"
require_relative "quint_driver/spec"
require_relative "quint_driver/model"
