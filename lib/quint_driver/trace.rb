module QuintDriver
  # A trace `quint run --mbt` wrote. Each state names the action the
  # simulator took and the values it picked, so a driver can run the same
  # command and be held to the next state.
  module Trace
    Step = Struct.new(:action, :picks, :expected, :index)

    # +state+ is the path to the record or map a driver is held to, such as
    # %w[choreo::s system] in a Choreo spec, which keeps the whole state in
    # one variable. +action+ is the path to a variable the spec records the
    # action in, as a sum type whose tag names the action and whose record
    # holds its picks; without it, the action is quint's mbt::actionTaken,
    # which `quint run --mbt` writes and quint test does not.
    def self.steps(path, state: [], action: nil)
      JSON.parse(File.read(path)).fetch("states").each_with_index.map do |values, index|
        values = decode(values)
        taken, picks = if action
                         at(values, action, index).then { _1.is_a?(String) ? [ _1, {} ] : _1 }
                       else
                         [ values.fetch("mbt::actionTaken") { raise Unsupported, "quint: state #{index} of the trace names no action taken; quint test writes no mbt::actionTaken, so pass action: the path to a variable that records it" },
                           values.fetch("mbt::nondetPicks") ]
                       end
        expected = at(values.reject { _1.start_with?("mbt::") }, state, index)
        unless expected.is_a?(Hash)
          raise Unsupported, "quint: state #{index} of the trace has #{state.join('.')} = #{Agreement.show(expected)}, " \
                             "which is no record or map; pass state: the path to the record or map the driver reports"
        end
        Step.new(taken, picks.reject { _2.nil? }, expected, index)
      end
    end

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
    # definition has in the trace's state. Returns the steps it ran, so a
    # caller can count the actions and states its traces reached.
    def self.replay(path, driver, log: nil, state: [], action: nil, spec: nil, observe: [])
      observe = observe.map(&:to_s)
      observed = observed(path, spec, observe)
      ran = []
      steps(path, state:, action:).each do |step|
        # An unnamed action names no command for the driver to run.
        raise Unsupported, "quint: step #{step.index} of #{path} took an anonymous action; name every action in step" if step.action.empty?

        log&.puts "step #{step.index} #{step.action} #{Agreement.show(step.picks)}"
        ran << [ step.action, step.picks ]
        at = "step #{step.index} `#{step.action}` #{Agreement.show(step.picks)}"
        actual = Agreement.drive(at, steps: ran) do
          driver.step(step.action, step.picks)
          driver.state
        end
        Agreement.check!(at, step.expected.merge(observed[step.index]), actual, by: "trace", steps: ran, observe:)
      end
    rescue Mismatch, StepRaised => failure
      Quint.send(:name_trace, failure, path)
      raise
    end

    # The value of each definition +observe+ names, in each state of the
    # trace. The model reads the state as quint wrote it, so the driver's
    # steps never pass through the model.
    def self.observed(path, spec, observe)
      return Hash.new({}) if observe.empty?
      raise ArgumentError, "quint: observe needs spec:, the Spec that evaluates #{observe.join(', ')}" unless spec

      spec.observable!(observe)
      model = spec.model(nil)
      JSON.parse(File.read(path)).fetch("states").map do |values|
        model.enter(decode(values.reject { _1.start_with?("mbt::") }) { |tag, inner| Model::Variant.new(tag, inner) })
        model.observe(observe)
      end
    end
    private_class_method :observed

    # ITF (https://apalache-mc.org/docs/adr/015adr-trace.html) to plain values.
    # `Option` None is nil and Some its value, so a nondet pick reads as a value.
    # With a block, a sum type's value is what the block makes of its tag and
    # its decoded value, as the model holds one.
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
          else inner == [] ? value["tag"] : [ value["tag"], inner ]
          end
        else value.except("#meta").transform_values { decode(_1, &variant) }
        end
      else value
      end
    end
  end
end
