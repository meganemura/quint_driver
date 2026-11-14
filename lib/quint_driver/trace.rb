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
        values = decode(itf)
        taken, picks = if action
                         at(values, action, index).then do
                           no_picks = {} #: picks
                           _1.is_a?(String) ? [ _1, no_picks ] : _1
                         end
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
    # @rbs picks: Hash[String, untyped]
    # @rbs return: picks
    def self.made(picks)
      picks.filter_map { |name, pick| [ name, decode(pick["value"]) ] if pick["tag"] == "Some" }.to_h
    end
    private_class_method :made

    # @rbs values: Hash[String, untyped]
    # @rbs path: Array[String]
    # @rbs index: Integer
    # @rbs return: untyped
    def self.at(values, path, index)
      path.each_with_index.reduce(values) do |value, (key, depth)|
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
    # @rbs return: Array[state] | Hash[Integer, state]
    def self.evaluated(path, spec, observe:, invariants:)
      names = observe | invariants
      none = {} #: state
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
        model.enter(decode(values) { |tag, inner| Model::Variant.new(tag, inner) })
        model.observe(names)
      end
    end
    private_class_method :evaluated

    # The spec's variables in state +index+ of the trace, as plain values.
    #
    # @rbs path: String
    # @rbs index: Integer
    # @rbs return: state
    def self.variables(path, index)
      decode(JSON.parse(File.read(path)).fetch("states").fetch(index)).reject { |name, _| name.start_with?("mbt::") }
    end
    private_class_method :variables

    # ITF (https://apalache-mc.org/docs/adr/015adr-trace.html) to plain values.
    # An Option is nil for None and its value for Some, as Model.plain gives one.
    # With a block, a sum type's value is what the block makes of its tag and
    # its decoded value, as the model holds one.
    #
    # @rbs value: untyped
    # @rbs &variant: ? (String tag, untyped inner) -> untyped
    # @rbs return: untyped
    def self.decode(value, &variant)
      case value
      when Array then value.map { decode(_1, &variant) }
      when Hash
        if value.key?("#set") then value["#set"].to_set { decode(_1, &variant) }
        elsif value.key?("#map") then value["#map"].to_h { |k, v| [ decode(k, &variant), decode(v, &variant) ] }
        elsif value.key?("#tup") then value["#tup"].map { decode(_1, &variant) }
        elsif value.key?("#bigint") then value["#bigint"].to_i
        elsif value.key?("tag") && value.key?("value")
          inner = decode(value["value"], &variant)
          return variant.(value["tag"], inner) if variant

          case value["tag"]
          when "None" then nil
          when "Some" then inner
          else inner == [] ? value["tag"] : [ value["tag"], inner ] # steep:ignore UnannotatedEmptyCollection
          end
        else value.except("#meta").transform_values { decode(_1, &variant) }
        end
      else value
      end
    end
  end
end
