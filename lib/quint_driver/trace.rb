module QuintDriver
  # A trace `quint run --mbt` wrote. Each state names the action the
  # simulator took and the values it picked, so a driver can run the same
  # command and be held to the next state.
  module Trace
    Step = Struct.new(:action, :picks, :expected, :index)

    def self.steps(path)
      JSON.parse(File.read(path)).fetch("states").each_with_index.map do |state, index|
        state = decode(state)
        picks = state.fetch("mbt::nondetPicks").reject { _2.nil? }
        Step.new(state.fetch("mbt::actionTaken"), picks, state.reject { _1.start_with?("mbt::") }, index)
      end
    end

    def self.replay(path, driver)
      steps(path).each do |step|
        # An unnamed action names no command for the driver to run.
        raise "quint: step #{step.index} of #{path} took an anonymous action; name every action in step" if step.action.empty?

        driver.step(step.action, step.picks)
        QuintDriver.compare!("step #{step.index} `#{step.action}` #{step.picks.inspect} of #{path}",
                             step.expected, driver.state, by: "trace")
      end
    end

    # ITF (https://apalache-mc.org/docs/adr/015adr-trace.html) to plain values.
    # `Option` None is nil and Some its value, so a nondet pick reads as a value.
    def self.decode(value)
      case value
      when Array then value.map { decode(_1) }
      when Hash
        if value.key?("#set") then value["#set"].to_set { decode(_1) }
        elsif value.key?("#map") then value["#map"].to_h { |k, v| [ decode(k), decode(v) ] }
        elsif value.key?("#tup") then value["#tup"].map { decode(_1) }
        elsif value.key?("#bigint") then value["#bigint"].to_i
        elsif value.key?("tag") && value.key?("value")
          inner = decode(value["value"])
          case value["tag"]
          when "None" then nil
          when "Some" then inner
          else inner == [] ? value["tag"] : [ value["tag"], inner ]
          end
        else value.except("#meta").transform_values { decode(_1) }
        end
      else value
      end
    end
  end
end
