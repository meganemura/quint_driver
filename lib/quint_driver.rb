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
# [tag, value] when it carries one. An Option, a sum type of None and Some,
# is nil or its value.
module QuintDriver
  # The trace a failure happened on. On a replay, +trace+ is its path. Under
  # Quint.simulate or Quint.test that file is gone once the block returns, so
  # +seed+ and +written_by+ hold the seed and the call that write it again,
  # and the message names the trace by those instead of by its path. The gem
  # fills these in, so a caller cannot name a trace that disagrees with the
  # one that ran.
  module NamedTrace
    attr_reader :trace, :seed, :written_by

    def to_s
      return super unless trace

      "#{super}\ntrace: #{written_by ? "#{File.basename(trace)} of #{written_by}" : trace}"
    end

    private
      def name_trace(trace, seed: nil, written_by: nil) = (@trace, @seed, @written_by = trace, seed, written_by)
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
    # variables +actual+ reports, and each definition +observe+ names, which
    # the driver has to report. The model evaluates an observed definition,
    # also on a trace's state, so its line names the model. +spec+, when the
    # caller has one, tells a name the driver reports that is no variable
    # apart from a definition it forgot to observe.
    def self.check!(after, expected, actual, by:, steps:, observe: [], spec: nil)
      compared = actual.keys | observe
      return if expected.slice(*compared) == actual

      lines = compared.reject { expected[_1] == actual[_1] }.map do |name|
        next [ by, unknown(name, actual[name], expected.keys - observe, by:, spec:) ] unless expected.key?(name)

        source = observe.include?(name) ? "model" : by
        [ source, "  #{name}: #{source} #{show(expected[name])}, driver #{show(actual[name])}" ]
      end
      raise Mismatch, "quint: after #{after}, the driver differs from the #{lines.map(&:first).uniq.join(' and the ')}\n" \
                      "#{lines.map(&:last).join("\n")}\n#{ran(steps)}", outside(caller_locations)
    end

    def self.unknown(name, reported, names, by:, spec:)
      within = by == "trace" ? "the trace's state, which has #{names.sort.join(', ')}" : "the spec's variables, #{names.sort.join(', ')}"
      hint = if spec.nil? then "; to hold the driver to a definition, pass spec: and observe:"
             elsif spec.send(:observable).include?(name) then "; it is a definition of the spec, so name it in observe:"
             else ""
             end
      "  #{name}: driver #{show(reported)}, but #{name} is not in #{within}#{hint}"
    end

    # Runs the block, the driver's part of the step named +at+, and returns
    # what it returns. An error the driver's own code raises comes out as
    # StepRaised with +steps+; the gem's own errors pass through.
    def self.drive(at, steps:)
      yield
    rescue Mismatch, StepRaised => failure
      raise lead_outside(failure)
    rescue Unsupported, QuintFailed
      raise
    rescue StandardError => error
      raise StepRaised, "quint: at #{at}, the step raised #{error.class}: #{error.message}\n#{raised_in(error)}#{ran(steps)}",
            outside(error.backtrace_locations || error.backtrace)
    end

    # +frames+ without quint_driver's own, nor Hegel's under the machine, so
    # the first line a test runner prints of a Mismatch or a StepRaised is
    # the driver's, the system's, or the test's: RSpec hides the frames of an
    # installed gem, but not of one a Gemfile loads from a path, and Minitest
    # hides none. Hegel groups the failures it shrinks by the first frame, so
    # the frames stay Locations where Ruby can set them, from 3.4 on.
    def self.outside(frames)
      kept = frames.reject { _1.to_s.start_with?(*@hidden) }
      kept = frames if kept.empty?
      RUBY_VERSION >= "3.4" ? kept : kept.map(&:to_s)
    end

    # A failure the driver or a caller's block raised, its backtrace +outside+.
    def self.lead_outside(failure)
      failure.tap { _1.set_backtrace(outside(_1.backtrace_locations || _1.backtrace)) }
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

      "raised in: #{relative(frame.to_s)}\n"
    end

    # A path as the project names it, as RSpec prints one, when it is under
    # the directory the run started in. That is the directory when the gem
    # loaded, as RSpec reads it once, so a driver that changes directory does
    # not turn the path absolute.
    def self.relative(path) = path.delete_prefix(STARTED_IN)
    STARTED_IN = File.join(Dir.pwd, "")

    QUINT_DRIVER = File.join(__dir__, "quint_driver")
    @hidden = [ QUINT_DRIVER ]

    # The Hegel adapter hides Hegel's frames too, as it is the one file that
    # knows where Hegel is.
    def self.hide(prefix) = @hidden << prefix

    LIBRARIES = [ QUINT_DRIVER, "<internal:", RbConfig::CONFIG["rubylibprefix"] + File::SEPARATOR,
                  *(defined?(Gem) ? Gem.path : []).map { File.join(_1, "") } ].freeze

    def self.library?(frame, *prefixes) = frame.path.start_with?(*prefixes)

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
