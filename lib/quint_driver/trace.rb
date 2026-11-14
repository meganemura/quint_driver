# rbs_inline: enabled

module QuintDriver
  # A trace `quint run --mbt` wrote. Each state names the action the
  # simulator took and the values it picked, so a driver can run the same
  # command and be held to the next state.
  module Trace
    Step = Struct.new(
      :action, #: String
      :picks, #: picks
      :expected, #: state
      :index #: Integer
    )

    # +state+ is the path to the record or map a driver is held to, such as
    # %w[choreo::s system] in a Choreo spec, which keeps the whole state in
    # one variable. +action+ is the path to a variable the spec records the
    # action in, as a sum type whose tag names the action and whose record
    # holds its picks; without it, the action is quint's mbt::actionTaken,
    # which `quint run --mbt` writes and quint test does not.
    #
    # @rbs path: String
    # @rbs state: Array[String]
    # @rbs action: Array[String]?
    # @rbs return: Array[Step]
    def self.steps(path, state: [], action: nil)
      JSON.parse(File.read(path)).fetch("states").each_with_index.map do |itf, index|
        # An ITF state is a record, by the name of each variable.
        values = decode(itf) #: Hash[String, plain]
        taken, picks = if action
                         # The variable is a sum type: a tag, or a tag and the
                         # record of its picks.
                         recorded = at(values, action, index) #: String | [String, picks]
                         no_picks = {} #: picks
                         recorded.is_a?(String) ? [ recorded, no_picks ] : recorded
                       else
                         [ values.fetch("mbt::actionTaken") { raise Unsupported, "quint: state #{index} of the trace names no action taken; quint test writes no mbt::actionTaken, so pass action: the path to a variable that records it" },
                           made(itf.fetch("mbt::nondetPicks")) ]
                       end
        expected = at(values.reject { _1.start_with?("mbt::") }, state, index)
        unless expected.is_a?(Hash)
          raise Unsupported, "quint: state #{index} of the trace has #{state.join('.')} = #{Agreement.show(expected)}, " \
                             "which is no record or map; pass state: the path to the record or map the driver reports"
        end
        Step.new(taken, picks, expected, index)
      end
    end

    # quint wraps each pick in an Option of its own: Some when the move made
    # it, None when it did not. Only that wrapper is taken off, so a pick the
    # move made of the spec's own None is nil and still present.
    #
    # @rbs picks: Hash[String, Hash[String, json]]
    # @rbs return: picks
    def self.made(picks)
      # decode gives plain values without a block.
      picks.filter_map { |name, pick| [ name, decode(pick["value"]) ] if pick["tag"] == "Some" }.to_h #: picks
    end
    private_class_method :made

    # @rbs values: Hash[String, plain]
    # @rbs path: Array[String]
    # @rbs index: Integer
    # @rbs return: plain
    def self.at(values, path, index)
      start = values #: plain
      path.each_with_index.reduce(start) do |value, (key, depth)|
        next value[key] if value.is_a?(Hash) && value.key?(key)

        within = path.take(depth).join(".")
        raise Unsupported, "quint: state #{index} of the trace has no #{path.take(depth + 1).join('.')}" \
                           "#{"; #{within} has #{value.keys.sort.join(', ')}" if value.is_a?(Hash)}"
      end
    end
    private_class_method :at

    # +log+, an IO such as $stdout, gets each step before the driver runs it.
    # +state+ and +action+ are paths into each state, as Trace.steps reads them.
    # +observe+ names definitions of +spec+, a Spec, that derive a value from
    # the variables, such as a total no variable holds: the driver reports
    # each one in its state by name, and is held to the value the spec's
    # definition has in the trace's state. +ignore+ names variables the
    # driver does not report, such as what a remote service answers, which
    # the spec models and the driver only reads to set the system up; the
    # driver reports every other variable. +invariants+ names predicates of
    # +spec+, expectations that have to hold in every state: once the driver
    # agrees at a step, one that is false in that step's state raises
    # Violated. Returns the steps it ran, so a caller can count the actions
    # and states its traces reached.
    #
    # @rbs path: String
    # @rbs driver: _Driver
    # @rbs log: _Log?
    # @rbs state: Array[String]
    # @rbs action: Array[String]?
    # @rbs spec: Spec?
    # @rbs observe: Array[String | Symbol]
    # @rbs ignore: Array[String | Symbol]
    # @rbs invariants: Array[String | Symbol]
    # @rbs return: Array[Step]
    def self.replay(path, driver, log: nil, state: [], action: nil, spec: nil, observe: [], ignore: [], invariants: [])
      observe, ignore, invariants = observe.map(&:to_s), ignore.map(&:to_s), invariants.map(&:to_s)
      evaluated = evaluated(path, spec, observe:, invariants:)
      ran = [] #: Array[step]
      steps = steps(path, state:, action:)
      Agreement.ignorable!(ignore, steps.first.expected.keys, "the trace's state") if steps.any?
      steps.each do |step|
        # An unnamed action names no command for the driver to run.
        raise Unsupported, "quint: step #{step.index} of #{path} took an anonymous action; name every action in step" if step.action.empty?

        log&.puts "step #{step.index} #{step.action} #{Agreement.show(step.picks)}"
        ran << [ step.action, step.picks ]
        at = "step #{step.index} `#{step.action}` #{Agreement.show(step.picks)}"
        actual = Agreement.drive(at, steps: ran) do
          driver.step(step.action, step.picks)
          driver.state
        end
        values = evaluated[step.index]
        Agreement.check!(at, step.expected.merge(values.slice(*observe)), actual, by: "trace", steps: ran, observe:, spec:, ignore:)
        broken = invariants.reject { values[_1] }
        Agreement.violated!(at, broken, steps: ran, state: variables(path, step.index)) if broken.any?
      end
    rescue NamedTrace => failure
      Quint.send(:name_trace, failure, path)
      raise
    end

    # The value of each definition +observe+ and +invariants+ name, in each
    # state of the trace, so a name refused or one the model cannot
    # evaluate fails before the driver runs a step. The model reads the
    # state as quint wrote it, so the driver's steps never pass through the
    # model; it reads only the spec's variables, so the mbt:: entries stay.
    #
    # @rbs path: String
    # @rbs spec: Spec?
    # @rbs observe: Array[String]
    # @rbs invariants: Array[String]
    # @rbs return: Array[Hash[String, plain]] | Hash[Integer, Hash[String, plain]]
    def self.evaluated(path, spec, observe:, invariants:)
      names = observe | invariants
      none = {} #: Hash[String, plain]
      return Hash.new(none) if names.empty?

      { "observe" => observe, "invariants" => invariants }.each do |argument, named|
        Agreement.refuse "quint: #{argument} needs spec:, the Spec that evaluates #{named.join(', ')}" if named.any? && !spec
      end
      # The loop above refused a nil spec, as names is not empty.
      spec = spec #: Spec
      spec.observable!(observe)
      spec.predicates!(invariants, "invariants")
      model = spec.model(nil)
      JSON.parse(File.read(path)).fetch("states").map do |values|
        # An ITF state is a record, and with a block decode gives the model's values.
        state = decode(values) { |tag, inner| Model::Variant.new(tag, inner) } #: Hash[String, Model::value]
        model.enter(state)
        model.observe(names)
      end
    end
    private_class_method :evaluated

    # The spec's variables in state +index+ of the trace, as plain values.
    #
    # @rbs path: String
    # @rbs index: Integer
    # @rbs return: Hash[String, plain]
    def self.variables(path, index)
      # An ITF state is a record, by the name of each variable.
      values = decode(JSON.parse(File.read(path)).fetch("states").fetch(index)) #: Hash[String, plain]
      values.reject { |name, _| name.start_with?("mbt::") }
    end
    private_class_method :variables

    # @rbs!
    #   # What decode gives: a plain value without a block, and the model's
    #   # value with one. Steep checks a body against each overload, and the
    #   # one body holds both cases, so each caller says which it reads.
    #   type decoded = nil | bool | Integer | String | Set[decoded] | Array[decoded] | Hash[decoded, decoded] | Model::Variant | Model::Closure

    # ITF (https://apalache-mc.org/docs/adr/015adr-trace.html) to plain values.
    # An Option is nil for None and its value for Some, as Model.plain gives one.
    # With a block, a sum type's value is what the block makes of its tag and
    # its decoded value, as the model holds one. An ITF value names its shape
    # by its keys, such as "#set", so each is read as the shape its key names.
    #
    # @rbs value: json
    # @rbs &variant: ? (String tag, Model::value inner) -> Model::value
    # @rbs return: decoded
    def self.decode(value, &variant)
      case value
      when Array then value.map { decode(_1, &variant) }
      when Hash
        if value.key?("#set")
          elements = value["#set"] #: Array[json]
          elements.to_set { decode(_1, &variant) }
        elsif value.key?("#map")
          pairs = value["#map"] #: Array[[json, json]]
          pairs.to_h { |k, v| [ decode(k, &variant), decode(v, &variant) ] }
        elsif value.key?("#tup")
          elements = value["#tup"] #: Array[json]
          elements.map { decode(_1, &variant) }
        elsif value.key?("#bigint")
          digits = value["#bigint"] #: String
          digits.to_i
        elsif value.key?("tag") && value.key?("value")
          tag = value["tag"] #: String
          inner = decode(value["value"], &variant)
          if variant
            held = inner #: Model::value
            return variant.(tag, held)
          end

          case tag
          when "None" then nil
          when "Some" then inner
          else inner == Model::UNIT ? tag : [ tag, inner ]
          end
        else value.except("#meta").transform_values { decode(_1, &variant) }
        end
      else
        # ITF writes no float: a number past an Integer's JSON is a #bigint.
        value #: nil | bool | Integer | String
      end
    end
  end
end
