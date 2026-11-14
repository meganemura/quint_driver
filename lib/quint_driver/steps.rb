# rbs_inline: enabled

# Runs a list of steps, such as the steps: lines a failure printed, on a
# driver and on the spec's model side by side, and checks them as a replay
# checks a trace. It needs no quint command and no Hegel, so a failure found
# by either is pinned as one plain example.
module QuintDriver
  # Runs +steps+ on +driver+ and on +spec+'s model, from init, and holds the
  # driver to the model after each one: a disagreement raises Mismatch, and
  # an expectation +invariants+ names that is false where the two agreed
  # raises Violated, as Trace.replay does. +steps+ is the text under steps:
  # of a failure, pasted as it is, or a list of [action, picks]; a first
  # step named init may be left out. +step+ names the spec's step action, as
  # QuintDriver.machine takes it. Returns the steps it ran.
  #
  # @rbs spec: Spec
  # @rbs driver: _Driver
  # @rbs steps: String | Array[[String | Symbol, Hash[String | Symbol, untyped]?]]
  # @rbs step: String
  # @rbs observe: Array[String | Symbol]
  # @rbs ignore: Array[String | Symbol]
  # @rbs invariants: Array[String | Symbol]
  # @rbs return: Array[step]
  def self.replay_steps(spec, driver, steps, step: "step", observe: [], ignore: [], invariants: [])
    observe, ignore, invariants = observe.map(&:to_s), ignore.map(&:to_s), invariants.map(&:to_s)
    steps = Steps.parse(steps) if steps.is_a?(String)
    steps = steps.map do |action, picks|
      given = picks || {} # steep:ignore UnannotatedEmptyCollection
      [ action.to_s, given.transform_keys(&:to_s) ] #: step
    end
    steps.unshift([ "init", {} ]) unless steps.first&.first == "init"
    spec.observable!(observe)
    spec.predicates!(invariants, "invariants")
    model = spec.model(step)
    ran = [] #: Array[step]
    steps.each_with_index do |(action, picks), index|
      ran << [ action, picks ]
      at = "step #{index} `#{action}` #{Agreement.show(picks)}"
      begin
        model.step(action, picks)
      rescue Mismatch => refused
        raise Mismatch, "#{refused.message}, at #{at}\n#{Agreement.ran(ran)}", Agreement.outside(caller_locations)
      end
      Agreement.ignorable!(ignore, model.state.keys, "the spec's variables") if index.zero?
      actual = Agreement.drive(at, steps: ran) do
        driver.step(action, picks)
        driver.state
      end
      Agreement.check!(at, model.state.merge(model.observe(observe)), actual, by: "model", steps: ran, observe:, spec:, ignore:)
      broken = invariants.reject { model.value(_1) }
      Agreement.violated!(at, broken, steps: ran, state: model.state) if broken.any?
    end
    ran
  end

  # Takes steps out of a failure while the same expectations still break,
  # and returns the shortest list it found as the text under steps:, to
  # paste into replay_steps. The block runs one list of steps, as
  # [action, picks] from init, and raises what replay_steps raises: it
  # builds the driver and rolls the database back each time, since a list
  # that keeps the failure is only known by running it. A list the spec
  # does not allow (Mismatch), one whose step raises (StepRaised), or one
  # that breaks other expectations does not keep the failure. Quint's first
  # trace that breaks an expectation is seldom the shortest; Hegel shrinks
  # its own.
  #
  # @rbs steps: String | Array[[String | Symbol, Hash[String | Symbol, untyped]?]]
  # @rbs &run: (Array[step] steps) -> void
  # @rbs return: String
  def self.shrink_steps(steps, &run)
    steps = Steps.parse(steps) if steps.is_a?(String)
    steps = steps.map do |action, picks|
      given = picks || {} # steep:ignore UnannotatedEmptyCollection
      [ action.to_s, given.transform_keys(&:to_s) ] #: step
    end
    steps.shift if steps.first&.first == "init"
    first = Steps.violated(steps, &run) or raise ArgumentError, "quint: shrink_steps needs steps that raise Violated; these do not"

    expectations = first.expectations.sort
    best = Steps.after_init(first.steps)
    # Runs of steps come out together, longest first, since a step often
    # needs the one before it: a save cannot go without its load.
    loop do
      shorter = best.size.downto(1).lazy.flat_map do |size|
        (0..best.size - size).lazy.filter_map do |start|
          candidate = best.dup.tap { _1.slice!(start, size) }
          broken = Steps.violated(candidate, &run)
          Steps.after_init(broken.steps) if broken && broken.expectations.sort == expectations
        end
      end.first
      break unless shorter

      best = shorter
    end
    Agreement.ran([ [ "init", {} ], *best ]) + "\n"
  end

  # Reads the steps: lines of a failure back into [action, picks]. Each line
  # is an action's name and its picks as a failure prints a value: strings,
  # integers, true, false, nil, [lists], {sets} and {hashes with =>}.
  module Steps
    # The Violated that running +steps+ raises, or nil when they keep every
    # expectation, the spec refuses one of them, or one of them raises.
    #
    # @rbs steps: Array[step]
    # @rbs &: (Array[step] steps) -> void
    # @rbs return: Violated?
    def self.violated(steps)
      yield([ [ "init", {} ], *steps ])
      nil
    rescue Violated => broken
      broken
    rescue Mismatch, StepRaised
      nil
    end

    # @rbs steps: Array[step]
    # @rbs return: Array[step]
    def self.after_init(steps) = steps.first&.first == "init" ? steps.drop(1) : steps

    # @rbs text: String
    # @rbs return: Array[step]
    def self.parse(text)
      text.each_line.map(&:strip).reject { _1.empty? || _1 == "steps:" }.map do |line|
        action, picks = line.split(" ", 2)
        reader = Reader.new(picks.to_s.strip)
        value = reader.value
        raise ArgumentError, "quint: replay_steps reads `#{line}`, whose picks are no {...} a failure prints" unless value.is_a?(Hash) && reader.done?

        # A line that is not empty splits into one word at least.
        [ action, value ] #: step
      end
    end

    # A small reader of Agreement.show's output; a set and a hash share
    # braces and tell apart by the => after the first element.
    class Reader
      # @rbs @text: String
      # @rbs @at: Integer

      # @rbs text: String
      # @rbs return: void
      def initialize(text) = (@text, @at = text, 0)

      # @rbs return: bool
      def done? = (skip; @at == @text.size)

      # @rbs return: untyped
      def value
        skip
        case @text[@at]
        when '"' then string
        when "[" then (@at += 1; list)
        when "{" then braces
        else word
        end
      end

      private
        # @rbs return: nil
        def skip = (@at += 1 while @text[@at] == " ")

        # @rbs token: String
        # @rbs return: Integer
        def take(token)
          skip
          raise ArgumentError, "quint: replay_steps expected #{token} at `#{@text[@at..]}`" unless @text[@at, token.size] == token

          @at += token.size
        end

        # @rbs return: String
        def string
          finish = @at + 1
          finish += @text[finish] == "\\" ? 2 : 1 until @text[finish] == '"' || finish >= @text.size
          literal = @text[@at..finish] #: String
          @at = finish + 1
          literal.undump
        end

        # @rbs return: bool | Integer | nil
        def word
          # @at is never past the end, so the rest is a string, empty at the end.
          token = @text[@at..][/\A[^,\]\}\s]+/] or raise ArgumentError, "quint: replay_steps cannot read `#{@text[@at..]}`" # steep:ignore NoMethod
          @at += token.size
          case token
          when "true" then true
          when "false" then false
          when "nil" then nil
          when /\A-?\d+\z/ then Integer(token)
          else raise ArgumentError, "quint: replay_steps cannot read #{token}"
          end
        end

        # @rbs return: Array[untyped]
        def list
          items = [] #: Array[untyped]
          skip
          until @text[@at] == "]"
            raise ArgumentError, "quint: replay_steps expected ] at the end of `#{@text}`" if @at >= @text.size

            items << value
            skip
            @at += 1 if @text[@at] == ","
            skip
          end
          @at += 1
          items
        end

        # @rbs return: Hash[untyped, untyped] | Set[untyped]
        def braces
          take("{")
          skip
          return (@at += 1; {}) if @text[@at] == "}" # steep:ignore UnannotatedEmptyCollection

          first = value
          skip
          return set_from(first) unless @text[@at, 2] == "=>"

          hash = {} #: Hash[untyped, untyped]
          key = first
          loop do
            take("=>")
            hash[key] = value
            skip
            break (@at += 1) if @text[@at] == "}"

            take(",")
            key = value
          end
          hash
        end

        # @rbs first: untyped
        # @rbs return: Set[untyped]
        def set_from(first)
          items = [ first ]
          until @text[@at] == "}"
            take(",")
            items << value
            skip
          end
          @at += 1
          items.to_set
        end
    end
  end
  private_constant :Steps
end
