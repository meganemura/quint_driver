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
  def self.replay_steps(spec, driver, steps, step: "step", observe: [], ignore: [], invariants: [])
    observe, ignore, invariants = observe.map(&:to_s), ignore.map(&:to_s), invariants.map(&:to_s)
    steps = Steps.parse(steps) if steps.is_a?(String)
    steps = steps.map { |action, picks| [ action.to_s, (picks || {}).transform_keys(&:to_s) ] }
    steps.unshift([ "init", {} ]) unless steps.first&.first == "init"
    spec.observable!(observe)
    spec.predicates!(invariants, "invariants")
    model = spec.model(step)
    ran = []
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

  # Reads the steps: lines of a failure back into [action, picks]. Each line
  # is an action's name and its picks as a failure prints a value: strings,
  # integers, true, false, nil, [lists], {sets} and {hashes with =>}.
  module Steps
    def self.parse(text)
      text.each_line.map(&:strip).reject { _1.empty? || _1 == "steps:" }.map do |line|
        action, picks = line.split(" ", 2)
        reader = Reader.new(picks.to_s.strip)
        value = reader.value
        raise ArgumentError, "quint: replay_steps reads `#{line}`, whose picks are no {...} a failure prints" unless value.is_a?(Hash) && reader.done?

        [ action, value ]
      end
    end

    # A small reader of Agreement.show's output; a set and a hash share
    # braces and tell apart by the => after the first element.
    class Reader
      def initialize(text) = (@text, @at = text, 0)
      def done? = (skip; @at == @text.size)

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
        def skip = (@at += 1 while @text[@at] == " ")

        def take(token)
          skip
          raise ArgumentError, "quint: replay_steps expected #{token} at `#{@text[@at..]}`" unless @text[@at, token.size] == token

          @at += token.size
        end

        def string
          finish = @at + 1
          finish += @text[finish] == "\\" ? 2 : 1 until @text[finish] == '"' || finish >= @text.size
          literal = @text[@at..finish]
          @at = finish + 1
          literal.undump
        end

        def word
          token = @text[@at..][/\A[^,\]\}\s]+/] or raise ArgumentError, "quint: replay_steps cannot read `#{@text[@at..]}`"
          @at += token.size
          case token
          when "true" then true
          when "false" then false
          when "nil" then nil
          when /\A-?\d+\z/ then Integer(token)
          else raise ArgumentError, "quint: replay_steps cannot read #{token}"
          end
        end

        def list
          items = []
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

        def braces
          take("{")
          skip
          return (@at += 1; {}) if @text[@at] == "}"

          first = value
          skip
          return set_from(first) unless @text[@at, 2] == "=>"

          hash = {}
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
