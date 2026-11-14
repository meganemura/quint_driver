# rbs_inline: enabled

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
  # @rbs!
  #   # A node, a declaration, or a whole module of quint's JSON IR, as
  #   # JSON.parse reads it.
  #   type ir = Hash[String, untyped]
  #
  #   # The values a move picked, by the name of each nondet pick.
  #   type picks = Hash[String, untyped]
  #
  #   # A state as plain values, by the name of each variable or definition.
  #   type state = Hash[String, untyped]
  #
  #   # One step a failure names: an action and its picks.
  #   type step = [String, picks]
  #
  #   # The driver protocol: run the action on the system, then report its
  #   # state as plain values.
  #   interface _Driver
  #     def step: (String action, picks picks) -> untyped
  #     def state: () -> state
  #   end
  #
  #   # Where a replay writes each step before it runs it, such as $stdout.
  #   interface _Log
  #     def puts: (*untyped) -> untyped
  #   end

  # The trace a failure happened on. On a replay, +trace+ is its path. Under
  # Quint.simulate or Quint.test that file is gone once the block returns, so
  # +seed+ and +written_by+ hold the seed and the call that write it again,
  # and the message names the trace by those instead of by its path. The gem
  # fills these in, so a caller cannot name a trace that disagrees with the
  # one that ran.
  #
  # @rbs module-self Exception
  module NamedTrace
    attr_reader :trace #: String?
    attr_reader :seed #: (String | Integer)?
    attr_reader :written_by #: String?

    # @rbs return: String
    def to_s
      return super unless trace

      "#{super}\ntrace: #{written_by ? "#{File.basename(trace)} of #{written_by}" : trace}"
    end

    private
      # @rbs trace: String
      # @rbs seed: (String | Integer)?
      # @rbs written_by: String?
      # @rbs return: void
      def name_trace(trace, seed: nil, written_by: nil) = (@trace, @seed, @written_by = trace, seed, written_by)
  end
  private_constant :NamedTrace

  # The system and the spec disagree. A driver or a check of the caller's own
  # raises one with a message alone, as `raise QuintDriver::Mismatch, "..."`.
  class Mismatch < StandardError
    include NamedTrace
  end

  # The system agreed with the spec at every step, and an expectation, a
  # predicate of the spec that invariants: names, does not hold: the spec
  # lets the system reach a state the expectation rules out. That is a bug
  # suspect, not a disagreement, so it is no Mismatch, and a caller that
  # rescues Mismatch does not catch it. The message names the expectation,
  # the steps from init, and the state where it broke.
  class Violated < StandardError
    include NamedTrace

    # The names of the expectations that broke, and the steps from init, as
    # [action, picks], that reached the state.
    attr_reader :expectations #: Array[String]
    attr_reader :steps #: Array[step]

    # @rbs message: String?
    # @rbs expectations: Array[String]
    # @rbs steps: Array[step]
    # @rbs return: void
    def initialize(message = nil, expectations: [], steps: [])
      super(message)
      @expectations, @steps = expectations, steps
    end
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
    # the failure can be run again without the trace file. The driver has to
    # report every variable but those +ignore+ names, and each definition
    # +observe+ names: a variable it leaves out would otherwise pass however
    # wrong the system's copy is. The model evaluates an observed definition,
    # also on a trace's state, so its line names the model. +spec+, when the
    # caller has one, tells a name the driver reports that is no variable
    # apart from a definition it forgot to observe.
    #
    # @rbs after: String
    # @rbs expected: state
    # @rbs actual: state
    # @rbs by: String
    # @rbs steps: Array[step]
    # @rbs observe: Array[String]
    # @rbs spec: Spec?
    # @rbs ignore: Array[String]
    # @rbs return: void
    def self.check!(after, expected, actual, by:, steps:, observe: [], spec: nil, ignore: [])
      expected, actual = expected.except(*ignore), actual.except(*ignore)
      return if expected == actual

      lines = (actual.keys | expected.keys).reject { expected.key?(_1) && actual.key?(_1) && expected[_1] == actual[_1] }.map do |name|
        next [ by, unknown(name, actual[name], expected.keys - observe, by:, spec:) ] unless expected.key?(name)

        source = observe.include?(name) ? "model" : by
        next [ source, "  #{name}: #{source} #{show(expected[name])}, driver #{show(actual[name])}" ] if actual.key?(name)

        fix = observe.include?(name) ? "report it, since observe: names it" : "report it, or name it in ignore: when the driver only reads it"
        [ source, "  #{name}: #{source} #{show(expected[name])}, but the driver's state leaves #{name} out; #{fix}" ]
      end
      raise Mismatch, "quint: after #{after}, the driver differs from the #{lines.map(&:first).uniq.join(' and the ')}\n" \
                      "#{lines.map(&:last).join("\n")}\n#{ran(steps)}", outside(caller_locations)
    end

    # Raises Violated naming each expectation in +broken+, which is false in
    # +state+, the spec's variables after +after+, once the driver agreed
    # with the spec at each of the [action, picks] +steps+ from init, the
    # last of which is +after+. The state is the spec's, so it holds the
    # variables ignore: names too, which an expectation can read.
    #
    # @rbs after: String
    # @rbs broken: Array[String]
    # @rbs steps: Array[step]
    # @rbs state: state
    # @rbs return: bot
    def self.violated!(after, broken, steps:, state:)
      expectations = "#{broken.one? ? 'expectation' : 'expectations'} #{broken.map { "`#{_1}`" }.join(' and ')}"
      variables = state.sort_by(&:first).map { |name, value| "  #{name}: #{show(value)}" }
      error = Violated.new("quint: the system agreed with the spec at every step, and the #{expectations} " \
                           "#{broken.one? ? 'does' : 'do'} not hold after #{after}\n#{ran(steps)}\nstate:\n#{variables.join("\n")}",
                           expectations: broken.dup, steps: steps.map { |action, picks| [ action, picks.dup ] })
      error.set_backtrace(outside(caller_locations))
      raise error
    end

    # A name +ignore+ holds that +names+ lacks is refused, so a misspelt name
    # reads as one rather than as its variable left out.
    #
    # @rbs ignore: Array[String]
    # @rbs names: Array[String]
    # @rbs within: String
    # @rbs return: void
    def self.ignorable!(ignore, names, within)
      unknown = ignore - names
      return if unknown.empty?

      refuse "quint: ignore names #{unknown.join(', ')}, which #{unknown.one? ? 'is' : 'are'} not in #{within}; it has #{names.sort.join(', ')}"
    end

    # @rbs name: String
    # @rbs reported: untyped
    # @rbs names: Array[String]
    # @rbs by: String
    # @rbs spec: Spec?
    # @rbs return: String
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
    #
    # @rbs [T] (String at, steps: Array[step]) { () -> T } -> T
    def self.drive(at, steps:)
      yield
    rescue NamedTrace => failure
      raise lead_outside(failure)
    rescue Unsupported, QuintFailed => failure
      raise lead_outside(failure)
    rescue StandardError => error
      raise StepRaised, "quint: at #{at}, the step raised #{error.class}: #{error.message}\n#{raised_in(error)}#{ran(steps)}",
            outside(error.backtrace_locations || error.backtrace)
    end

    # +frames+ without quint_driver's own, nor Hegel's under the machine, so
    # the first line a test runner prints of a Mismatch or a StepRaised is
    # the driver's, the system's, or the test's: RSpec hides the frames of an
    # installed gem, but not of one a Gemfile loads from a path, and Minitest
    # hides none. Hegel groups the failures it shrinks by the first frame, so
    # the frames stay Locations where Ruby can set them, from 3.4 on. Ruby's
    # own <internal:...> frames go too: on 3.4 a Kernel method written in
    # Ruby, between Hegel's frames and the test's, would lead otherwise.
    #
    # The frames are untyped: they are Locations or strings, and nil for an
    # error never raised, while set_backtrace takes each kind through an
    # overload of its own, which Steep cannot choose from a union.
    #
    # @rbs frames: untyped
    # @rbs return: untyped
    def self.outside(frames)
      kept = frames.reject { _1.to_s.start_with?(*@hidden, "<internal:") }
      kept = frames if kept.empty?
      RUBY_VERSION >= "3.4" ? kept : kept.map(&:to_s)
    end

    # Raises +error+ (ArgumentError by default) with +message+ from the line
    # that called quint_driver: the argument it is about, or the spec quint
    # failed on, is that caller's. The frames of Ruby's library between two
    # of quint_driver's, such as Dir.mktmpdir's, go too.
    #
    # @rbs message: String
    # @rbs error: singleton(Exception)
    # @rbs return: bot
    def self.refuse(message, error = ArgumentError)
      frames = caller_locations
      last = frames.rindex { _1.to_s.start_with?(*@hidden) }
      raise error, message, outside(last ? frames.drop(last + 1) : frames)
    end

    # A failure the driver or a caller's block raised, its backtrace +outside+.
    #
    # +failure+ is untyped because a rescue of NamedTrace gives the module
    # type, which RBS cannot make a subtype of Exception.
    #
    # @rbs failure: untyped
    # @rbs return: untyped
    def self.lead_outside(failure)
      failure.tap { _1.set_backtrace(outside(_1.backtrace_locations || _1.backtrace)) }
    end

    # The project's frame nearest the raise, the one to read first: an error
    # raised inside a gem or Ruby's library names the line that called it.
    # The frames below quint_driver's are the caller of the replay or the
    # machine, so they are never the step's. An error with no frames of its
    # own, such as one raised with a backtrace of strings, names none.
    #
    # @rbs error: Exception
    # @rbs return: String?
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
    #
    # @rbs path: String
    # @rbs return: String
    def self.relative(path) = path.delete_prefix(STARTED_IN)
    STARTED_IN = File.join(Dir.pwd, "") #: String

    QUINT_DRIVER = File.join(
      __dir__, #: String
      "quint_driver"
    ) #: String

    # @rbs self.@hidden: Array[String]
    @hidden = [ QUINT_DRIVER ]

    # The Hegel adapter hides Hegel's frames too, as it is the one file that
    # knows where Hegel is.
    #
    # @rbs prefix: String
    # @rbs return: Array[String]
    def self.hide(prefix) = @hidden << prefix

    LIBRARIES = [ QUINT_DRIVER, "<internal:", RbConfig::CONFIG["rubylibprefix"] + File::SEPARATOR,
                  *(defined?(Gem) ? Gem.path : [] #: Array[String]
                   ).map { File.join(_1, "") } ].freeze #: Array[String]

    # @rbs frame: Thread::Backtrace::Location
    # @rbs *prefixes: String
    # @rbs return: bool
    def self.library?(frame, *prefixes)
      # A frame of a backtrace always has a path; RBS allows nil for a
      # Location built by hand.
      path = frame.path #: String
      path.start_with?(*prefixes)
    end

    # @rbs steps: Array[step]
    # @rbs return: String
    def self.ran(steps) = "steps:\n#{steps.map { |action, picks| "  #{action} #{show(picks)}" }.join("\n")}"

    # A plain value as a failure prints it: a set's elements and a hash's
    # keys sorted, so the spec's side and the driver's side, and a replay and
    # the machine, print the same value the same way on every Ruby.
    #
    # @rbs value: untyped
    # @rbs return: String
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
require_relative "quint_driver/steps"
require_relative "quint_driver/outline"
require_relative "quint_driver/hold"
require_relative "quint_driver/targets"
