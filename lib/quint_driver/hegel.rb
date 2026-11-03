# The Hegel adapter. It is the one file that loads hegeltest, which needs
# Ruby 3.4, so trace replay and the model run without it.
require "hegel"
require_relative "../quint_driver"

module QuintDriver
  # A Hegel::StateMachine for +spec+'s +step+ action. Hegel picks each move,
  # the model takes it, the driver runs the same command on the system, and
  # the two states have to be equal afterwards. Hegel owns every choice, so a
  # failure shrinks to a short sequence of commands.
  #
  # +choose+ is how a move is drawn:
  # - :rule, Hegel picks a rule and a disabled one is rejected (tc.assume).
  #   Shrinks to the shortest sequence; deep states take more test cases.
  # - :rotate, a disabled rule passes the turn to the next enabled one.
  #   Nothing is rejected, so deep states come sooner; shrinking leaves extra
  #   moves, because a draw means a different rule once the state differs.
  def self.machine(spec, driver:, step: "step", invariants: [], choose: :rule)
    rules = spec.rules(step)
    # Many draws map to one sequence of moves, so the shrinker asks for the
    # same sequence thousands of times: on one failure, 8818 test cases held
    # 1342 distinct sequences. A sequence the system already agreed on is not
    # run again. That assumes the system answers a sequence the same way each
    # time, which the shrinker assumes too. A disagreement is never kept: it
    # runs on the system every time, so the failure reported is one it
    # reproduced.
    agreed = Set.new
    # A fixed domain (Spec::Rule#fixed) is the same list in every test case,
    # so it is evaluated and sorted once per machine, not once per draw.
    fixed = {}.compare_by_identity

    Class.new(Hegel::StateMachine) do
      define_method(:initialize) do
        @model = spec.model(step)
        @model.step("init", {})
        @moves = []
        @ran = 0 # how many of @moves the driver has run
      end

      define_method(:move!) do |action, picks, after|
        @model.enter(after)
        @moves << [ action, Model.plain(picks) ]
        return if agreed.include?(@moves)

        init = [ "init", {} ]
        unless @driver
          actual = Agreement.drive("init", steps: [ init ]) do
            @driver = driver.call
            @driver.step(*init)
            @driver.state
          end
          Agreement.check!("init", spec.model(step).tap { _1.step(*init) }.state, actual, by: "model", steps: [ init ])
        end
        # Every move the driver has not run yet, which is more than the last
        # one when the driver skipped a sequence it agreed on.
        while @ran < @moves.size
          move = @moves[@ran]
          Agreement.drive("`#{move[0]}` #{Agreement.show(move[1])}", steps: [ init, *@moves[..@ran] ]) { @driver.step(*move) }
          @ran += 1
        end
        at = "`#{action}` #{Agreement.show(@moves.last.last)}"
        actual = Agreement.drive(at, steps: [ init, *@moves ]) { @driver.state }
        Agreement.check!(at, @model.state, actual, by: "model", steps: [ init, *@moves ])
        agreed << @moves.dup
      end

      case choose
      when :rule
        rules.each do |rule|
          rule(rule.action) do |tc|
            picks = rule.domains.each_with_object({}) do |(name, domain), chosen|
              choices = fixed.fetch(domain) do
                sorted = @model.value(domain, chosen, within: rule.within).to_a.sort_by(&:to_s).freeze
                rule.fixed.include?(name) ? fixed[domain] = sorted : sorted
              end
              tc.assume(choices.any?)
              chosen[name] = tc.draw(sampled_from(choices), label: name)
            end
            after = @model.try(rule.action, rule.args.map { @model.value(_1, picks, within: rule.within) })
            tc.assume(after)
            tc.note { "#{rule.action} #{Model.plain(picks)}" }
            move!(rule.action, picks, after)
          end
        end
      when :rotate
        rule(step) do |tc|
          start = tc.draw(integers(min_value: 0, max_value: rules.size - 1), label: "rule")
          moves = rules.rotate(start).lazy.map { @model.moves(_1) }.find(&:any?)
          tc.assume(moves)
          action, picks, after = tc.draw(sampled_from(moves), label: "move")
          tc.note { "#{action} #{Model.plain(picks)}" }
          move!(action, picks, after)
        end
      else raise ArgumentError, "quint: choose is :rule or :rotate"
      end

      # Hegel samples an invariant between moves unless always_run is set;
      # an invariant here holds after every move.
      invariants.each do |name|
        invariant(name, always_run: true) do
          raise Mismatch, "quint: the model broke `#{name}`" unless @model.value(name.to_s) == true
        end
      end
    end
  end
end
