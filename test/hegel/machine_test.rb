require_relative "../test_helper"
require "quint_driver/hegel"
require "stringio"
require "tmpdir"

class MachineTest < Minitest::Test
  SETTINGS = { test_cases: 100, seed: 1, suppress_health_check: %i[filter_too_much too_slow] }.freeze
  GEM_FRAME = /\A#{Regexp.escape(File.expand_path("../../lib", __dir__))}\//
  HEGEL_FRAME = /\A#{Regexp.escape(File.dirname(Hegel::Stateful.method(:run).source_location.first))}/

  %i[rule rotate].each do |choose|
    define_method(:"test_#{choose}_passes_a_system_that_follows_the_spec") do
      machine = machine(Loans, choose)

      Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    define_method(:"test_#{choose}_draws_no_pick_from_an_empty_set") do
      spec = QuintDriver::Spec.new(File.expand_path("../operators.qnt", __dir__), main: "operators")
      machine = QuintDriver.machine(spec, driver: -> { spec.model }, choose:)

      Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    define_method(:"test_#{choose}_hands_a_driver_plain_picks_of_a_sum_type") do
      spec = QuintDriver::Spec.new(File.expand_path("../operators.qnt", __dir__), main: "painting")
      machine = QuintDriver.machine(spec, driver: -> { spec.model }, choose:)

      Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    define_method(:"test_#{choose}_stops_a_sequence_where_no_move_is_enabled") do
      spec = QuintDriver::Spec.new(File.expand_path("../operators.qnt", __dir__), main: "countdown")
      machine = QuintDriver.machine(spec, driver: -> { spec.model }, choose:)

      Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    define_method(:"test_#{choose}_shrinks_a_broken_system_to_two_moves") do
      machine = machine(BrokenLoans, choose)
      report = StringIO.new

      error = assert_raises(QuintDriver::Mismatch) do
        Hegel.test(**SETTINGS, output: report) { |tc| Hegel::Stateful.run(machine.new, tc) }
      end

      moves = report.string.scan(/^\s+(borrow\S*|give_back\S*) \{.*\}$/).flatten
      assert_equal %w[borrow borrow_refused], moves
      assert_equal(choose == :rule ? moves : %w[step] * moves.size, report.string.scan(/^  Step \d+: (\S+)$/).flatten, "Hegel's report names a move by its action")
      step = error.message[/\Aquint: after step (\d+) `borrow_refused` /, 1]
      assert_equal report.string.scan(/^  Step (\d+): /).flatten.last, step, "the message numbers the move as Hegel's report does"
      assert_match(/outcome: model \["Refused", "limit_reached"\], driver "Done"/, error.message)
      assert_equal [ "init", *moves ], error.message[/^steps:\n((?:  .*\n?)+)/, 1].to_s.lines.map { _1.split.first }
      assert_match(/^  borrow \{"b" => "b\d", "m" => "m\d"\}$/, error.message, "picks print in the order a replay prints them")
      names = report.string.scan(/^\s+([a-z]+)_\d+ = /).flatten.uniq.sort
      assert_equal(choose == :rule ? %w[b m] : %w[move rule], names)
    end
  end

  def test_the_system_runs_a_sequence_it_agreed_on_only_once
    runs = []
    recording = Class.new(LoansDriver) do
      define_method(:initialize) { |*args| super(*args); runs << (@moves = []) }
      define_method(:step) { |action, picks| @moves << [ action, picks ]; super(action, picks) }
    end
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { recording.new })

    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }

    assert_operator runs.size, :>, 1
    assert_equal runs.uniq, runs
  end

  def test_the_machine_evaluates_a_domain_that_reads_no_variable_and_no_pick_once
    reads = Hash.new(0)
    spec = QuintDriver::Spec.new(File.expand_path("../operators.qnt", __dir__), main: "pairing")
    domains = spec.rules("step").flat_map { |rule| rule.domains.map { |name, domain| [ domain, "#{rule.action} #{name}" ] } }.to_h.compare_by_identity
    counted = spec.clone
    counted.define_singleton_method(:model) do |step|
      super(step).tap do |model|
        model.define_singleton_method(:value) { |node, *rest, **options| reads[domains[node]] += 1 if domains.key?(node); super(node, *rest, **options) }
      end
    end
    machine = QuintDriver.machine(counted, driver: -> { spec.model })

    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }

    assert_equal 1, reads["pair a"]
    assert_operator reads["pair b"], :>, 100
    assert_operator reads["unpair p"], :>, 100
  end

  def test_an_invariant_holds_on_every_state_hegel_reaches
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new }, invariants: %i[one_book_each])

    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
  end

  def test_an_invariant_is_checked_on_every_state_a_move_reaches
    events = []
    spec = LoansDriver.spec.clone
    spec.define_singleton_method(:model) do |step|
      super(step).tap do |model|
        model.define_singleton_method(:enter) { |after| events << [ model, :move ]; super(after) }
        model.define_singleton_method(:value) { |name, *rest, **options| events << [ model, :check ] if name == "one_book_each"; super(name, *rest, **options) }
      end
    end
    machine = QuintDriver.machine(spec, driver: -> { LoansDriver.new }, invariants: %i[one_book_each])

    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }

    # The model that gives the driver's first state takes init and is never checked.
    after_moves = events.group_by(&:first).values.select { _1.size > 1 }.flat_map do |model_events|
      kinds = model_events.map(&:last)
      kinds.each_index.select { kinds[_1] == :move }.map { kinds[_1 + 1] }
    end
    assert_operator after_moves.size, :>, 100
    assert_equal [ :check ], after_moves.uniq
  end

  def test_a_broken_invariant_fails_at_the_first_state_that_breaks_it
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new }, invariants: %i[nothing_on_loan])

    error = assert_raises(QuintDriver::Violated) do
      Hegel.test(**SETTINGS, output: StringIO.new) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end
    assert_equal <<~MESSAGE.chomp, error.message
      quint: the system agreed with the spec at every step, and the expectation `nothing_on_loan` does not hold after step 1 `borrow` {"b" => "b1", "m" => "m1"}
      steps:
        init {}
        borrow {"b" => "b1", "m" => "m1"}
      state:
        holder: {"b1" => "m1", "b2" => "", "b3" => ""}
        outcome: "Done"
    MESSAGE
    assert_empty error.backtrace.grep(GEM_FRAME)
    assert_empty error.backtrace.grep(HEGEL_FRAME)
    assert_equal __FILE__, error.backtrace_locations.first.path, "the test's own line leads"
  end

  # unlimited.qnt models BrokenLoans as written, so the system agrees with
  # the spec at every move, and only the expectation finds the bug.
  %i[rule rotate].each do |choose|
    define_method(:"test_#{choose}_shrinks_an_expectation_a_system_that_agrees_breaks_to_two_moves") do
      machine = QuintDriver.machine(unlimited, driver: -> { LoansDriver.new(BrokenLoans) }, invariants: %w[one_book_each], choose:)
      report = StringIO.new

      error = assert_raises(QuintDriver::Violated) do
        Hegel.test(**SETTINGS, output: report) { |tc| Hegel::Stateful.run(machine.new, tc) }
      end

      refute_kind_of QuintDriver::Mismatch, error
      assert_equal <<~MESSAGE.chomp, error.message
        quint: the system agreed with the spec at every step, and the expectation `one_book_each` does not hold after step 2 `borrow` {"b" => "b2", "m" => "m1"}
        steps:
          init {}
          borrow {"b" => "b1", "m" => "m1"}
          borrow {"b" => "b2", "m" => "m1"}
        state:
          holder: {"b1" => "m1", "b2" => "m1", "b3" => ""}
          outcome: "Done"
      MESSAGE
      assert_equal "2", report.string.scan(/^  Step (\d+): /).flatten.last, "the message numbers the move as Hegel's report does"
    end
  end

  def test_a_system_that_disagrees_on_the_move_that_breaks_an_expectation_fails_with_a_mismatch
    machine = QuintDriver.machine(unlimited, driver: -> { LoansDriver.new(Loans) }, invariants: %w[one_book_each])

    error = assert_raises(QuintDriver::Mismatch) do
      Hegel.test(**SETTINGS, output: StringIO.new) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    assert_match(/\Aquint: after step 2 `borrow` \{"b" => "b2", "m" => "m1"\}, the driver differs from the model\n/, error.message)
    assert_match(/^  outcome: model "Done", driver \["Refused", "limit_reached"\]$/, error.message)
  end

  def test_an_expectation_that_holds_passes_a_system_with_a_bug_it_does_not_rule_out
    machine = QuintDriver.machine(unlimited, driver: -> { LoansDriver.new(BrokenLoans) }, invariants: %w[lent_to_members])

    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
  end

  def test_an_expectation_false_at_init_fails_before_hegel_takes_a_step
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new }, invariants: %w[two_on_loan])
    report = StringIO.new

    error = assert_raises(QuintDriver::Violated) do
      Hegel.test(**SETTINGS, output: report) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    assert_equal <<~MESSAGE.chomp, error.message
      quint: the system agreed with the spec at every step, and the expectation `two_on_loan` does not hold after step 0 `init` {}
      steps:
        init {}
      state:
        holder: {"b1" => "", "b2" => "", "b3" => ""}
        outcome: "Done"
    MESSAGE
    refute_match(/Step \d/, report.string, "Hegel's report lists no step")
  end

  def test_the_machine_refuses_an_expectation_that_is_no_predicate_before_hegel_runs
    { "borrow" => "an action with parameters of loans", "onLoan" => "a def with parameters of loans",
      "BOOKS" => "a set value of loans", "nobody" => "which loans neither declares nor imports" }.each do |name, what|
      error = assert_raises(ArgumentError) { QuintDriver.machine(LoansDriver.spec, driver: -> { flunk }, invariants: [ name ]) }

      assert_equal "quint: invariants names #{name}, #{what}; invariants takes a predicate, a boolean val or def without parameters, " \
                   "such as nothing_on_loan, one_book_each, two_on_loan", error.message
      assert_equal __FILE__, error.backtrace_locations.first.path
    end
  end

  def test_an_error_the_driver_raises_names_its_move_and_the_shrunk_steps
    misspelled = Class.new(LoansDriver) { def step(action, picks) = action.start_with?("give_back") ? picks.fetch("book") : super }
    line = __LINE__ - 1
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { misspelled.new })

    report = StringIO.new
    error = assert_raises(QuintDriver::StepRaised) do
      Hegel.test(**SETTINGS, output: report) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    first, raised_in, *steps = error.message.lines
    assert_match(/\Aquint: at step #{report.string.scan(/^  Step (\d+): /).flatten.last} `(give_back\S*)` \{"b" => "b\d"\}, the step raised KeyError: key not found: "book"$/, first)
    assert_match(/\Araised in: test\/hegel\/machine_test\.rb:#{line}:in .*fetch'\n\z/, raised_in)
    assert_equal [ "steps:\n", "  init {}\n", "  #{first[/`(.*)`/, 1]} #{first[/(\{.*\})/, 1]}" ], steps
    assert_equal KeyError, error.cause.class
    assert_equal [ __FILE__, line ], error.backtrace_locations.first.then { [ _1.path, _1.lineno ] }, "Hegel groups failures by the first frame"
    assert_empty error.backtrace.grep(GEM_FRAME)
  end

  def test_an_error_the_driver_s_state_raises_after_a_move_lists_the_steps_to_it
    unreadable = Class.new(LoansDriver) { def state = super.tap { raise "no holder" if _1["holder"].value?("m1") } }
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { unreadable.new })

    error = assert_raises(QuintDriver::StepRaised) do
      Hegel.test(**SETTINGS, output: StringIO.new) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    first, _raised_in, *steps = error.message.lines
    assert_match(/\Aquint: at step \d+ `borrow` (\{"b" => "b\d", "m" => "m1"\}), the step raised RuntimeError: no holder$/, first)
    assert_equal [ "steps:\n", "  init {}\n", "  borrow #{first[/(\{.*\})/, 1]}" ], steps
  end

  # Quint keeps a set's elements in no order a reader sees, so the machine
  # draws from them sorted, and a failure shrinks to the first by name.
  def test_a_failure_shrinks_to_the_first_pick_by_name_whatever_order_the_spec_writes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "shuffled.qnt")
      File.write(path, "module shuffled {\n  var picked: str\n  action init = picked' = \"\"\n  action pick(x: str): bool = picked' = x\n" \
                       "  action step = {\n    nondet x = Set(\"c\", \"a\", \"b\").oneOf()\n    any { pick(x) }\n  }\n}\n")
      spec = QuintDriver::Spec.new(path, main: "shuffled")
      lagging = Class.new { define_method(:initialize) { @model = spec.model }; def step(*move) = @model.step(*move); def state = { "picked" => "" } }
      machine = QuintDriver.machine(spec, driver: -> { lagging.new })

      error = assert_raises(QuintDriver::Mismatch) do
        Hegel.test(**SETTINGS, output: StringIO.new) { |tc| Hegel::Stateful.run(machine.new, tc) }
      end

      assert_match(/^  picked: model "a", driver ""$/, error.message)
    end
  end

  def test_an_error_the_driver_raises_at_init_fails_before_hegel_takes_a_step
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { Class.new(LoansDriver) { def state = raise("no state yet") }.new })
    line = __LINE__ - 1
    report = StringIO.new

    error = assert_raises(QuintDriver::StepRaised) do
      Hegel.test(**SETTINGS, output: report) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    assert_equal "quint: at step 0 `init` {}, the step raised RuntimeError: no state yet\n", error.message.lines.first
    assert_match(/\Araised in: test\/hegel\/machine_test\.rb:#{line}:in .*state'\nsteps:\n  init \{\}\z/, error.message.lines.drop(1).join)
    refute_match(/Step \d/, report.string, "Hegel's report lists no step the driver did not reach")
  end

  def test_a_driver_that_disagrees_at_init_fails_before_hegel_takes_a_step
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { Class.new(LoansDriver) { def state = super.merge("outcome" => "Busy") }.new })
    report = StringIO.new

    error = assert_raises(QuintDriver::Mismatch) do
      Hegel.test(**SETTINGS, output: report) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    assert_match(/\Aquint: after step 0 `init` \{\}, the driver differs from the model\n  outcome: model "Done", driver "Busy"\nsteps:\n  init \{\}\z/, error.message)
    refute_match(/Step \d/, report.string, "Hegel's report lists no step the driver did not reach")
    assert_empty error.backtrace.grep(GEM_FRAME)
    assert_empty error.backtrace.grep(HEGEL_FRAME)
    assert_equal __FILE__, error.backtrace_locations.first.path, "the test's own line leads"
  end

  # A test database keeps its rows from one test case to the next unless
  # the driver's init deletes them. Each driver the machine starts is held
  # to the model at init, also when an earlier machine already agreed on it.
  def test_a_driver_whose_init_keeps_an_earlier_test_case_s_state_fails_at_init
    shared = Loans.new
    keeping = Class.new(LoansDriver) do
      define_method(:step) { |action, picks| action == "init" ? (@loans, @outcome = shared, "Done") : super(action, picks) }
    end
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { keeping.new })

    error = assert_raises(QuintDriver::Mismatch) do
      Hegel.test(**SETTINGS, output: StringIO.new) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    assert_match(/\Aquint: after step 0 `init` \{\}, the driver differs from the model\n  holder: model \{"b1" => "", "b2" => "", "b3" => ""\}, driver /, error.message)
    assert_match(/\nsteps:\n  init \{\}\z/, error.message)
  end

  def test_the_machine_holds_the_driver_to_each_definition_it_observes
    lent = ->(count) { Class.new(LoansDriver) { define_method(:state) { super().then { _1.merge("two_on_loan" => count.(_1["holder"].count { |_, holder| holder != "" })) } } } }
    right = QuintDriver.machine(LoansDriver.spec, driver: -> { lent.(->(n) { n == 2 }).new }, observe: %w[two_on_loan])
    wrong = QuintDriver.machine(LoansDriver.spec, driver: -> { lent.(->(n) { n >= 1 }).new }, observe: %w[two_on_loan])

    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(right.new, tc) }
    error = assert_raises(QuintDriver::Mismatch) do
      Hegel.test(**SETTINGS, output: StringIO.new) { |tc| Hegel::Stateful.run(wrong.new, tc) }
    end
    assert_match(/\Aquint: after step 1 `borrow` \{"b" => "b1", "m" => "m1"\}, the driver differs from the model\n  two_on_loan: model false, driver true\n/, error.message)
    by_symbol = QuintDriver.machine(LoansDriver.spec, driver: -> { lent.(->(n) { n == 2 }).new }, observe: %i[two_on_loan])
    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(by_symbol.new, tc) }
  end

  def test_a_name_the_driver_reports_that_is_no_variable_says_so_and_names_a_definition_as_one
    { "dueCents" => "", "two_on_loan" => "; it is a definition of the spec, so name it in observe:" }.each do |name, hint|
      reporting = Class.new(LoansDriver) { define_method(:state) { super().merge(name => 0) } }
      machine = QuintDriver.machine(LoansDriver.spec, driver: -> { reporting.new })

      error = assert_raises(QuintDriver::Mismatch) { Hegel.test(**SETTINGS, output: StringIO.new) { |tc| Hegel::Stateful.run(machine.new, tc) } }
      assert_match(/\Aquint: after step 0 `init` \{\}, the driver differs from the model\n  #{name}: driver 0, but #{name} is not in the spec's variables, holder, outcome#{Regexp.escape(hint)}\nsteps:\n/, error.message)
    end
  end

  def test_the_machine_refuses_to_observe_a_name_that_is_no_definition_without_parameters
    error = assert_raises(ArgumentError) { QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new }, observe: %w[borrow]) }

    assert_match(/\Aquint: observe names borrow, which is no definition without parameters of loans; it has /, error.message)
  end

  def test_the_machine_refuses_a_module_without_an_action_named_init
    spec = QuintDriver::Spec.new(File.expand_path("../kinds.qnt", __dir__), main: "begins")
    error = assert_raises(ArgumentError) { QuintDriver.machine(spec, driver: -> { flunk }) }

    assert_match(/\Aquint: begins neither declares nor imports an action named init; /, error.message)
  end

  # Reports the last approver as an app does: a name, or nil for none.
  class ApprovalDriver
    def step(action, picks)
      @last, @approvals = nil, 0 if action == "init"
      @last, @approvals = picks.fetch("by"), @approvals + 1 if action == "approve"
    end

    def state = { "last" => @last, "approvals" => @approvals, "approved" => !@last.nil? }
  end

  def test_a_driver_reads_an_option_as_nil_or_its_value_on_a_replay_and_under_the_machine
    operators = File.expand_path("../operators.qnt", __dir__)
    spec = QuintDriver::Spec.new(operators, main: "approval")
    lasts = Set.new
    QuintDriver::Quint.simulate(operators, main: "approval", traces: 10, max_steps: 5, seed: "2") do |path|
      QuintDriver::Trace.replay(path, ApprovalDriver.new, spec:, observe: %w[approved]).each { lasts << _1.expected["last"] }
    end
    machine = QuintDriver.machine(spec, driver: -> { ApprovalDriver.new }, observe: %w[approved])

    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
    assert_equal Set[nil, "grace", "ada"], lasts
  end

  %i[rule rotate].each do |choose|
    define_method(:"test_#{choose}_draws_a_pick_of_false_when_false_is_the_only_choice") do
      operators = File.expand_path("../operators.qnt", __dir__)
      spec = QuintDriver::Spec.new(operators, main: "switch")
      picks = Set.new
      machine = QuintDriver.machine(spec, choose:, driver: -> {
        spec.model.tap { |model| model.define_singleton_method(:step) { |action, chosen| picks << [ action, chosen["b"] ]; super(action, chosen) } }
      })

      Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
      assert_includes picks, [ "flip", false ]
    end
  end

  def test_the_machine_fails_a_driver_that_leaves_out_a_variable_unless_it_ignores_it
    holder_only = Class.new(LoansDriver) { def state = super.slice("holder") }
    leaving = QuintDriver.machine(LoansDriver.spec, driver: -> { holder_only.new })
    ignoring = QuintDriver.machine(LoansDriver.spec, driver: -> { holder_only.new }, ignore: %i[outcome])

    error = assert_raises(QuintDriver::Mismatch) { Hegel.test(**SETTINGS, output: StringIO.new) { |tc| Hegel::Stateful.run(leaving.new, tc) } }
    assert_match(/\Aquint: after step 0 `init` \{\}, the driver differs from the model\n  outcome: model "Done", but the driver's state leaves outcome out; /, error.message)
    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(ignoring.new, tc) }
    error = assert_raises(ArgumentError) { QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new }, ignore: %w[outcomes]) }
    assert_equal "quint: ignore names outcomes, which is not in the spec's variables; it has holder, outcome", error.message
  end

  def test_a_choice_other_than_rule_or_rotate_raises
    error = assert_raises(ArgumentError) { QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new }, choose: :random) }

    assert_equal "quint: choose is :rule or :rotate", error.message
  end

  def test_the_adapter_adds_only_the_machine_to_quint_driver
    # replay_steps and shrink_steps are the core's; the adapter adds the machine and nothing else.
    assert_equal %i[machine replay_steps shrink_steps], QuintDriver.singleton_methods.sort
  end

  def self.unlimited = @unlimited ||= QuintDriver::Spec.new(File.expand_path("../unlimited.qnt", __dir__), main: "unlimited")

  private
    def machine(system, choose)
      QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new(system) }, choose:)
    end

    def unlimited = self.class.unlimited
end
