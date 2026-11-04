require "rbconfig"
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
  # The trace a failure happened on. On a replay, +trace+ is its path. Under
  # Quint.simulate that file is gone once the block returns, so +seed+ and
  # +simulate+ hold the seed and the call that write it again, and the message
  # names the trace by those instead of by its path. Replay and simulate fill
  # these in, so a caller cannot name a trace that disagrees with the one that
  # ran.
  module NamedTrace
    attr_reader :trace, :seed, :simulate

    def to_s
      return super unless trace

      "#{super}\ntrace: #{simulate ? "#{File.basename(trace)} of #{simulate}" : trace}"
    end

    private
      def name_trace(trace, seed: nil, simulate: nil) = (@trace, @seed, @simulate = trace, seed, simulate)
  end
  private_constant :NamedTrace

  # The system and the spec disagree. A driver or a check of the caller's own
  # raises one with a message alone, as `raise QuintDriver::Mismatch, "..."`.
  class Mismatch < StandardError
    include NamedTrace
  end

  # A step raised: the driver's code, or the system's beneath it, while it
  # ran a step or reported its state, so the spec and the system were never
  # compared. The message names the step, the project's frame that raised,
  # and the steps from init. The backtrace is the error's, and +cause+ is the
  # error.
  class StepRaised < StandardError
    include NamedTrace
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
      raise Mismatch, "quint: after #{after}, the driver differs from the #{by}\n#{diff.join("\n")}\n#{ran(steps)}"
    end

    # Runs the block, the driver's part of the step named +at+, and returns
    # what it returns. An error the driver's own code raises comes out as
    # StepRaised with +steps+; the gem's own errors pass through.
    def self.drive(at, steps:)
      yield
    rescue Mismatch, StepRaised, Unsupported, QuintFailed
      raise
    rescue StandardError => error
      # Hegel groups the failures it shrinks by the first frame of the
      # backtrace, so the driver's frames have to stay Locations; Ruby 3.3
      # sets a backtrace from Strings only.
      backtrace = RUBY_VERSION >= "3.4" ? error.backtrace_locations || error.backtrace : error.backtrace
      raise StepRaised, "quint: at #{at}, the step raised #{error.class}: #{error.message}\n#{raised_in(error)}#{ran(steps)}", backtrace
    end

    # The project's frame nearest the raise, the one to read first: an error
    # raised inside a gem or Ruby's library names the line that called it.
    # The frames below quint_driver's are the caller of the replay or the
    # machine, so they are never the step's. An error with no frames of its
    # own, such as one raised with a backtrace of strings, names none.
    def self.raised_in(error)
      frames = error.backtrace_locations or return
      frame = frames.take_while { !library?(_1, QUINT_DRIVER) }.find { !library?(_1, *LIBRARIES) }
      return "raised in: no frame of the project; every frame is in a gem, in Ruby's library, or in quint_driver\n" unless frame

      # The path as the project names it, as RSpec prints one, when the
      # frame is under the directory the run started in.
      "raised in: #{file(frame).delete_prefix(File.join(Dir.pwd, ""))}#{frame.to_s.delete_prefix(frame.path)}\n"
    end

    QUINT_DRIVER = File.join(__dir__, "quint_driver")
    LIBRARIES = [ QUINT_DRIVER, "<internal:", RbConfig::CONFIG["rubylibprefix"] + File::SEPARATOR,
                  *(defined?(Gem) ? Gem.path : []).map { File.join(_1, "") } ].freeze

    def self.library?(frame, *prefixes) = file(frame).start_with?(*prefixes)
    def self.file(frame) = frame.absolute_path || frame.path

    def self.ran(steps) = "steps:\n#{steps.map { |action, picks| "  #{action} #{show(picks)}" }.join("\n")}"

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
