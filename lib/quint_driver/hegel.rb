# The Hegel adapter. It is the one file that loads hegeltest, which needs
# Ruby 3.4, so trace replay and the model run without it.
require "hegel"
require_relative "../quint_driver"

module QuintDriver
  Agreement.hide(File.dirname(Hegel::Stateful.method(:run).source_location.first))

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
  #
  # +observe+ names definitions of the spec, as Trace.replay takes them: the
  # driver reports each one in its state, held to the model's value.
  def self.machine(spec, driver:, step: "step", invariants: [], choose: :rule, observe: [])
    rules = spec.rules(step)
    observe = observe.map(&:to_s)
    spec.observable!(observe)
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

    init = [ "init", {} ].freeze
    # A replay names a step by its index in the trace, init being step 0; the
    # machine names a move by the number Hegel's report gives it.
    at = ->(number, (action, picks)) { "step #{number} `#{action}` #{Agreement.show(picks)}" }

    Class.new(Hegel::StateMachine) do
      # The driver starts with the machine, before Hegel's first step, so a
      # failure at init is reported with no step Hegel took. Once init agreed,
      # the empty sequence is kept like any other, and a later machine starts
      # its driver only on a move that is not.
      define_method(:initialize) do
        @model = spec.model(step)
        @model.step(*init)
        @start = @model.state.merge(@model.observe(observe))
        @moves = []
        @numbers = [] # the Hegel step of each move
        @step = 0 # every rule Hegel ran, a rejected one too, as its report counts
        @ran = 0 # how many of @moves the driver has run
        next if agreed.include?(@moves)

        start_driver
        agreed << []
      end

      # Every driver is held to the model at init, also one started after an
      # earlier machine agreed on init: a test database keeps the rows of an
      # earlier test case unless the driver's init deletes them, and without
      # this check the first move would take the blame for them.
      define_method(:start_driver) do
        actual = Agreement.drive(at.(0, init), steps: [ init ]) do
          @driver = driver.call
          @driver.step(*init)
          @driver.state
        end
        Agreement.check!(at.(0, init), @start, actual, by: "model", steps: [ init ], observe:)
      end

      define_method(:move!) do |action, picks, after|
        @model.enter(after)
        @moves << [ action, Model.plain(picks) ]
        @numbers << @step
        return if agreed.include?(@moves)

        start_driver unless @driver
        # Every move the driver has not run yet, which is more than the last
        # one when the driver skipped a sequence it agreed on.
        while @ran < @moves.size
          move = @moves[@ran]
          Agreement.drive(at.(@numbers[@ran], move), steps: [ init, *@moves[..@ran] ]) { @driver.step(*move) }
          @ran += 1
        end
        last = at.(@numbers.last, @moves.last)
        actual = Agreement.drive(last, steps: [ init, *@moves ]) { @driver.state }
        Agreement.check!(last, @model.state.merge(@model.observe(observe)), actual, by: "model", steps: [ init, *@moves ], observe:)
        agreed << @moves.dup
      end

      case choose
      when :rule
        rules.each do |rule|
          rule(rule.action) do |tc|
            @step += 1
            picks = rule.domains.each_with_object({}) do |(name, domain), chosen|
              choices = fixed.fetch(domain) do
                sorted = @model.value(domain, chosen).to_a.sort_by(&:to_s).freeze
                rule.fixed.include?(name) ? fixed[domain] = sorted : sorted
              end
              tc.assume(choices.any?)
              chosen[name] = tc.draw(sampled_from(choices), label: name)
            end
            after = @model.try(rule.action, rule.args.map { @model.value(_1, picks) })
            tc.assume(after)
            tc.note { "#{rule.action} #{Model.plain(picks)}" }
            move!(rule.action, picks, after)
          end
        end
      when :rotate
        rule(step) do |tc|
          @step += 1
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
          raise Mismatch, "quint: the model broke `#{name}`", Agreement.outside(caller_locations) unless @model.value(name.to_s) == true
        end
      end
    end
  end
end
