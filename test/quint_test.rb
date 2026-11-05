require_relative "test_helper"
require "tmpdir"

class QuintTest < Minitest::Test
  MISSING = File.expand_path("missing.qnt", __dir__)
  RECORDED = File.expand_path("recorded.qnt", __dir__)
  OPERATORS = File.expand_path("operators.qnt", __dir__)
  KINDS = File.expand_path("kinds.qnt", __dir__)

  def test_simulating_runs_the_module_it_names
    states = []
    QuintDriver::Quint.simulate(OPERATORS, main: "countdown", traces: 3, max_steps: 2, seed: "1") do |path|
      states << QuintDriver::Trace.steps(path).map(&:expected)
    end

    assert_equal [ [ { "n" => 2 }, { "n" => 1 }, { "n" => 0 } ] ] * 3, states
  end

  def test_a_spec_reads_its_module_from_a_file_named_after_none_of_them
    Dir.mktmpdir do |dir|
      several = File.join(dir, "several.qnt")
      File.write(several, File.read(OPERATORS))

      assert_equal %w[tick], QuintDriver::Spec.new(several, main: "countdown").rules("step").map(&:action)
    end
  end

  def test_the_rust_evaluator_writes_the_states_quint_run_writes
    through_quint_run = with_env("QUINT_EVALUATOR" => "") { simulated_states }
    evaluator = QuintDriver::Quint.evaluator
    skip "quint has not downloaded its Rust evaluator #{QuintDriver::Quint::EVALUATOR_VERSION}" unless evaluator

    Dir.mktmpdir do |dir|
      # The evaluator through a wrapper that counts its calls, so the states
      # are known to come from it and not from `quint run`.
      counting = File.join(dir, "counting-evaluator")
      File.write(counting, "#!/bin/sh\necho \"$1\" >> #{dir}/ran\nexec #{evaluator} \"$@\"\n")
      File.chmod(0o755, counting)

      assert_equal through_quint_run, with_env("QUINT_EVALUATOR" => counting) { simulated_states }
      assert_equal "simulate-from-stdin\n" * 4, File.read(File.join(dir, "ran"))
    end
  end

  def test_an_evaluator_that_answers_in_another_format_raises
    Dir.mktmpdir do |dir|
      other = File.join(dir, "other-evaluator")
      [ '{"traces": []}', "[]", "no JSON at all", '{"bestTraces": {}}', '{"bestTraces": [{"states": []}]}' ].each do |answer|
        File.write(other, "#!/bin/sh\ncat > /dev/null\necho '#{answer}'\n")
        File.chmod(0o755, other)

        error = with_env("QUINT_EVALUATOR" => other) do
          assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.simulate(OPERATORS, main: "countdown", traces: 1, max_steps: 1, seed: "1") { flunk } }
        end
        assert_equal "quint: the Rust evaluator #{other} answered in a format quint_driver does not read; it reads the v0.7.0 evaluator " \
                     "quint 0.33.0 runs. Set QUINT_EVALUATOR to that evaluator, or to an empty string to simulate through `quint run`", error.message, answer
      end
    end
  end

  # The evaluator can print other lines around its answer; the answer is
  # its last line that is a JSON object.
  def test_the_answer_of_an_evaluator_is_its_last_json_line
    evaluator = QuintDriver::Quint.evaluator
    skip "quint has not downloaded its Rust evaluator #{QuintDriver::Quint::EVALUATOR_VERSION}" unless evaluator
    expected = []
    QuintDriver::Quint.simulate(OPERATORS, main: "countdown", traces: 2, max_steps: 2, seed: "1") { expected << QuintDriver::Trace.steps(_1).map(&:to_a) }
    Dir.mktmpdir do |dir|
      chatty = File.join(dir, "chatty-evaluator")
      File.write(chatty, "#!/bin/sh\necho '{\"progress\": 0}'\n#{evaluator} \"$@\"\nprintf '\\ndone\\n'\n")
      File.chmod(0o755, chatty)
      written = []
      with_env("QUINT_EVALUATOR" => chatty) do
        QuintDriver::Quint.simulate(OPERATORS, main: "countdown", traces: 2, max_steps: 2, seed: "1") { written << QuintDriver::Trace.steps(_1).map(&:to_a) }
      end

      assert_equal expected, written
    end
  end

  def test_an_evaluator_that_fails_or_reports_an_error_raises_with_its_reason
    Dir.mktmpdir do |dir|
      evaluator = File.join(dir, "evaluator")
      errors = '[{"code": "QNT503", "message": "division by zero"}, {"code": "QNT504", "message": "out of range"}]'
      { "echo 'evaluator crashed' >&2; exit 1" => /\Aquint: the Rust evaluator #{evaluator} failed:\nevaluator crashed/,
        %(echo '{"status": "error", "errors": #{errors}, "bestTraces": []}') =>
          /\Aquint run failed:\nError \[QNT503\]: division by zero\nError \[QNT504\]: out of range\z/ }
        .each do |script, reason|
          File.write(evaluator, "#!/bin/sh\ncat > /dev/null\n#{script}\n")
          File.chmod(0o755, evaluator)

          error = with_env("QUINT_EVALUATOR" => evaluator) do
            assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.simulate(OPERATORS, main: "countdown", traces: 1, max_steps: 1, seed: "1") { flunk } }
          end
          assert_match(reason, error.message)
        end
    end
  end

  def test_a_seed_that_is_not_an_integer_raises
    error = assert_raises(QuintDriver::QuintFailed) do
      QuintDriver::Quint.simulate(OPERATORS, main: "countdown", traces: 1, max_steps: 1, seed: "one") { flunk }
    end
    assert_equal 'quint: the seed "one" is not an integer', error.message
  end

  def test_a_simulation_that_reaches_a_definition_ends_each_trace_at_the_first_state_where_it_holds
    [ {}, { "QUINT_EVALUATOR" => "" } ].each do |env|
      lent = []
      simulate = ->(&block) { QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 5, max_steps: 10, seed: "1", reach: "two_on_loan", &block) }
      error = with_env(env) do
        simulate.() do |path|
          lent << QuintDriver::Trace.steps(path).map { |step| step.expected["holder"].values.count { _1 != "" } }
          QuintDriver::Trace.replay(path, LoansDriver.new)
        end
        assert_raises(QuintDriver::Mismatch) { simulate.() { raise QuintDriver::Mismatch, "quint: checked" } }
      end

      refute_empty lent, env.inspect
      lent.each { |counts| assert_equal counts.size - 1, counts.index(2), "each trace ends where two books are first lent: #{counts}" }
      assert_match(/, reach: "two_on_loan"\)\z/, error.written_by)
    end
  end

  def test_a_simulation_where_no_trace_reaches_the_definition_raises
    [ {}, { "QUINT_EVALUATOR" => "" } ].each do |env|
      error = with_env(env) do
        assert_raises(QuintDriver::QuintFailed) do
          QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 3, max_steps: 1, seed: "1", reach: "two_on_loan") { flunk }
        end
      end
      assert_equal "quint: no trace of 3 reached two_on_loan within 1 steps; raise max_steps or traces", error.message, env.inspect
    end
  end

  def test_a_simulation_toward_a_definition_runs_on_the_evaluator
    skip "quint has not downloaded its Rust evaluator #{QuintDriver::Quint::EVALUATOR_VERSION}" unless QuintDriver::Quint.evaluator
    Dir.mktmpdir do |dir|
      counting = File.join(dir, "counting-quint")
      File.write(counting, "#!/bin/sh\necho \"$1\" >> #{dir}/ran\nexec #{QuintDriver::Quint.command} \"$@\"\n")
      File.chmod(0o755, counting)
      reached = 0
      with_env("QUINT" => counting) do
        QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 5, max_steps: 10, seed: "1", reach: "two_on_loan") { reached += 1 }
      end

      assert_operator reached, :>, 0
      refute_includes File.exist?(File.join(dir, "ran")) ? File.readlines(File.join(dir, "ran")) : [], "run\n"
    end
  end

  def test_a_named_run_writes_the_states_it_ran
    books = []
    QuintDriver::Quint.test(RECORDED, "lendTest", seed: "1") do |path|
      books << JSON.parse(File.read(path))["states"].map { QuintDriver::Trace.decode(_1)["s"]["books"] }
    end

    assert_equal [ [ { "b1" => "", "b2" => "" }, { "b1" => "m1", "b2" => "" }, { "b1" => "m1", "b2" => "m2" }, { "b1" => "", "b2" => "m2" } ] ], books
  end

  def test_a_named_run_that_fails_in_quint_raises_with_quints_report
    error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.test(RECORDED, "unlentTest", seed: "1") { flunk } }

    assert_match(/\Aquint test failed:\n.*1\) unlentTest failed after 1 test/m, error.message)
  end

  def test_a_named_run_in_a_module_not_named_after_its_file_runs_with_main
    Dir.mktmpdir do |dir|
      shelf = File.join(dir, "shelf.qnt")
      File.write(shelf, "module shelf {\n  pure val BOOKS = Set(\"b1\")\n}\n" + File.read(RECORDED))
      written = []
      QuintDriver::Quint.test(shelf, "lendTest", seed: "1", main: "recorded") { written << JSON.parse(File.read(_1))["states"].size }

      assert_equal [ 4 ], written
    end
  end

  def test_a_run_the_module_does_not_have_lists_the_runs_it_has
    error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.test(RECORDED, "lend", seed: "1") { flunk } }

    assert_equal "quint: no run is named lend in recorded; it has lendTest, unlentTest", error.message
  end

  def test_the_typescript_backend_runs_quint_not_the_evaluator
    states = with_env("QUINT_EVALUATOR" => "/nonexistent/quint_evaluator") do
      list = []
      QuintDriver::Quint.simulate(OPERATORS, main: "countdown", traces: 1, max_steps: 2, seed: "1", backend: "typescript") do |path|
        list << QuintDriver::Trace.steps(path).map(&:expected)
      end
      list
    end
    assert_equal [ [ { "n" => 2 }, { "n" => 1 }, { "n" => 0 } ] ], states
  end

  # The two evaluators report a step or a reach of the wrong kind each in
  # its own words, so simulate checks the kind before either runs.
  def test_a_step_that_is_no_action_without_parameters_or_a_reach_that_is_no_predicate_raises_before_quint_runs
    actions = "such as step"
    predicates = "such as nothing_on_loan, one_book_each, two_on_loan"
    { { step: "one_book_each" } => "step names one_book_each, a predicate of loans; step takes an action without parameters, #{actions}",
      { step: "holder" } => "step names holder, a variable of loans; step takes an action without parameters, #{actions}",
      { step: "borrow" } => "step names borrow, an action with parameters of loans; step takes an action without parameters, #{actions}",
      { reach: "borrow" } => "reach names borrow, an action with parameters of loans; reach takes a predicate, a boolean val or def without parameters, #{predicates}",
      { reach: "step" } => "reach names step, an action of loans; reach takes a predicate, a boolean val or def without parameters, #{predicates}",
      { reach: "holder" } => "reach names holder, a variable of loans; reach takes a predicate, a boolean val or def without parameters, #{predicates}",
      { reach: "onLoan" } => "reach names onLoan, a def with parameters of loans; reach takes a predicate, a boolean val or def without parameters, #{predicates}",
      { reach: "BOOKS" } => "reach names BOOKS, a set value of loans; reach takes a predicate, a boolean val or def without parameters, #{predicates}",
      { reach: "Done" } => "reach names Done, a case of a sum type of loans; reach takes a predicate, a boolean val or def without parameters, #{predicates}" }.each do |names, message|
      [ {}, { "QUINT_EVALUATOR" => "" } ].each do |env|
        ran = quint_subcommands do
          error = with_env(env) { assert_raises(ArgumentError) { QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 3, max_steps: 3, seed: "1", **names) { flunk } } }
          assert_equal "quint: #{message}", error.message, [ names, env ].inspect
        end
        refute_includes ran, "run", names.inspect
      end
    end
  end

  def test_a_step_or_a_reach_of_each_kind_of_declaration_raises_with_that_kind
    actions = "step takes an action without parameters, such as step"
    predicates = "reach takes a predicate, a boolean val or def without parameters, such as at_limit, done"
    { { step: "Status" } => "step names Status, a type of kinds; #{actions}",
      { step: "LIMIT" } => "step names LIMIT, a constant of kinds; #{actions}",
      { step: "Lent" } => "step names Lent, a case of a sum type of kinds; #{actions}",
      { step: "add" } => "step names add, an action with parameters of kinds; #{actions}",
      { step: "walk" } => "step names walk, a run of kinds; #{actions}",
      { reach: "always_small" } => "reach names always_small, a temporal formula of kinds; #{predicates}",
      { reach: "double" } => "reach names double, a def with parameters of kinds; #{predicates}",
      { reach: "MAX" } => "reach names MAX, an int value of kinds; #{predicates}",
      { reach: "BOOKS" } => "reach names BOOKS, a set value of kinds; #{predicates}" }.each do |names, message|
      error = assert_raises(ArgumentError) { QuintDriver::Quint.simulate(KINDS, main: "kinds", traces: 1, max_steps: 1, seed: "1", **names) { flunk } }
      assert_equal "quint: #{message}", error.message, names.inspect
    end
  end

  def test_a_step_or_a_reach_that_names_nothing_raises_with_the_names_that_fit
    { { step: "borow" } => "step names borow, which loans neither declares nor imports; step takes an action without parameters, such as step",
      { reach: "two_lent" } => "reach names two_lent, which loans neither declares nor imports; " \
                               "reach takes a predicate, a boolean val or def without parameters, such as nothing_on_loan, one_book_each, two_on_loan" }.each do |names, message|
      [ {}, { "QUINT_EVALUATOR" => "" } ].each do |env|
        error = with_env(env) { assert_raises(ArgumentError) { QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 1, max_steps: 1, seed: "1", **names) { flunk } } }
        assert_equal "quint: #{message}", error.message, [ names, env ].inspect
      end
    end
  end

  # uses_base declares no action of its own, not even one named step.
  def test_a_step_the_module_imports_runs
    actions = []
    QuintDriver::Quint.simulate(KINDS, main: "uses_base", traces: 1, max_steps: 2, seed: "1", step: "base_step") do |path|
      actions = QuintDriver::Trace.steps(path).map(&:action)
    end
    assert_equal %w[init base_step base_step], actions
  end

  # Nothing uses_base declares reaches started or B::base_step, and quint keeps
  # an imported definition only where one of the module reaches it.
  def test_a_module_without_a_step_keeps_every_definition_it_imports_on_the_model
    model = QuintDriver::Spec.new(KINDS, main: "uses_base").model("moves")
    model.step("init", {})
    assert_equal({ "started" => false }, model.observe(%w[started]))
    model.step("base_step", {})
    assert_equal({ "shared" => 1 }, model.state)
    assert_equal({ "started" => true }, model.observe(%w[started]))

    names = QuintDriver::Spec.new(KINDS, main: "names_base").declarations.map { _1["name"] }
    assert_includes names, "B::base_step"
  end

  def test_traces_through_quint_run_come_in_the_order_quint_numbers_them
    names = with_env("QUINT_EVALUATOR" => "") do
      [].tap { |list| QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 12, max_steps: 2, seed: "1") { list << File.basename(_1) } }
    end

    assert_equal 12.times.map { "trace_#{_1}.itf.json" }, names
  end

  def test_the_evaluator_quint_downloaded_is_the_executable_one_named_for_the_platform
    Dir.mktmpdir do |home|
      folder = File.join(home, "rust-evaluator-#{QuintDriver::Quint::EVALUATOR_VERSION}")
      Dir.mkdir(folder)
      with_env("QUINT_HOME" => home, "QUINT_EVALUATOR" => nil) do
        File.write(File.join(folder, "quint_evaluator"), "")
        assert_nil QuintDriver::Quint.evaluator, "a file quint did not make executable"
        File.chmod(0o755, File.join(folder, "quint_evaluator"))
        assert_equal File.join(folder, "quint_evaluator"), QuintDriver::Quint.evaluator

        File.write(File.join(folder, "quint_evaluator.exe"), "")
        File.chmod(0o755, File.join(folder, "quint_evaluator.exe"))
        on_windows = Gem.method(:win_platform?)
        Gem.define_singleton_method(:win_platform?) { true }
        begin
          assert_equal File.join(folder, "quint_evaluator.exe"), QuintDriver::Quint.evaluator
        ensure
          Gem.define_singleton_method(:win_platform?, on_windows)
        end
      end
    end
  end

  def test_an_evaluator_that_is_not_installed_raises
    error = with_env("QUINT_EVALUATOR" => "/nonexistent/quint_evaluator") do
      assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.simulate(OPERATORS, main: "countdown", traces: 1, max_steps: 1, seed: "1") { flunk } }
    end
    assert_equal "quint: cannot run the Rust evaluator /nonexistent/quint_evaluator; set QUINT_EVALUATOR to it, or to an empty string " \
                 "to simulate through `quint run` (No such file or directory - /nonexistent/quint_evaluator)", error.message
  end

  def test_a_spec_compiles_once_until_its_text_changes
    Dir.mktmpdir do |dir|
      counting = File.join(dir, "counting-quint")
      File.write(counting, "#!/bin/sh\necho \"$1\" >> #{dir}/ran\nexec #{QuintDriver::Quint.command} \"$@\"\n")
      File.chmod(0o755, counting)
      spec = File.join(dir, "countdown.qnt")
      File.write(spec, "module countdown {\n  var n: int\n  action init = n' = 2\n  action tick = n' = n - 1\n  action step = any { tick }\n}\n")
      previous, ENV["QUINT"] = ENV["QUINT"], counting

      2.times { assert_equal %w[tick], QuintDriver::Spec.new(spec, main: "countdown").rules("step").map(&:action) }
      assert_equal "compile\n", File.read(File.join(dir, "ran"))

      File.write(spec, File.read(spec).gsub("tick", "tock"))
      assert_equal %w[tock], QuintDriver::Spec.new(spec, main: "countdown").rules("step").map(&:action)
      assert_equal "compile\ncompile\n", File.read(File.join(dir, "ran"))
      assert_raises(FrozenError) { QuintDriver::Quint.compile(spec, main: "countdown")["modules"] << {} }
    ensure
      ENV["QUINT"] = previous
    end
  end

  # An app's checkout can sit in a folder such as "Work Projects", and quint
  # runs through a shell.
  def test_a_spec_in_a_folder_whose_name_a_shell_splits_compiles_simulates_and_runs
    Dir.mktmpdir do |dir|
      folder = File.join(dir, "it's a $folder")
      Dir.mkdir(folder)
      spec = File.join(folder, "recorded.qnt")
      File.write(spec, File.read(RECORDED).sub(/\n}\s*\z/, "\n  val lent = s.books.get(\"b1\") != \"\"\n}\n"))
      File.write(File.join(folder, "lending.qnt"), "module lending {\n  import recorded.* from \"./recorded\"\n  action step2 = step\n}\n")

      assert_equal %w[borrow give_back], QuintDriver::Spec.new(spec, main: "recorded").rules("step").map(&:action)
      assert_equal %w[borrow give_back], QuintDriver::Spec.new(File.join(folder, "lending.qnt"), main: "lending").rules("step").map(&:action)
      [ {}, { "QUINT_EVALUATOR" => "" } ].each do |env|
        traces = 0
        with_env(env) { QuintDriver::Quint.simulate(spec, traces: 2, max_steps: 2, seed: "1", reach: "lent") { traces += 1 } }
        assert_operator traces, :>, 0, env.inspect
      end
      written = []
      QuintDriver::Quint.test(spec, "lendTest", seed: "1") { written << JSON.parse(File.read(_1))["states"].size }
      assert_equal [ 4 ], written
    end
  end

  def test_a_module_that_imports_its_definitions_and_actions_runs_on_the_model
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "start.qnt"), "module start {\n  pure val START = 2\n}\n")
      File.write(File.join(dir, "lib", "shelf.qnt"), "module shelf {\n  import start.* from \"start\"\n  pure val FROM = START\n}\n")
      spec = File.join(dir, "countdown.qnt")
      File.write(spec, "module ticks {\n  import shelf.* from \"./lib/shelf\"\n  var n: int\n  action init = n' = FROM\n" \
                       "  action tick = all { n > 0, n' = n - 1 }\n}\n\nmodule countdown {\n  import ticks.* from \"./countdown\"\n" \
                       "  action step = any { tick }\n}\n")
      model = QuintDriver::Spec.new(spec, main: "countdown").model

      model.step("init", {})
      model.step("tick", {})
      assert_equal({ "n" => 1 }, model.state)
      assert_equal %w[tick], QuintDriver::Spec.new(spec, main: "countdown").rules("step").map(&:action)
    end
  end

  def test_threads_that_ask_for_one_spec_at_once_compile_it_once
    Dir.mktmpdir do |dir|
      counting = File.join(dir, "counting-quint")
      File.write(counting, "#!/bin/sh\necho \"$1\" >> #{dir}/ran\nexec #{QuintDriver::Quint.command} \"$@\"\n")
      File.chmod(0o755, counting)
      spec = File.join(dir, "countdown.qnt")
      File.write(spec, "module countdown {\n  var n: int\n  action init = n' = 2\n  action tick = n' = n - 1\n  action step = any { tick }\n}\n")
      previous, ENV["QUINT"] = ENV["QUINT"], counting

      rules = 3.times.map { Thread.new { QuintDriver::Spec.new(spec, main: "countdown").rules("step").map(&:action) } }.map(&:value)
      assert_equal [ %w[tick] ] * 3, rules
      assert_equal "compile\n", File.read(File.join(dir, "ran"))
    ensure
      ENV["QUINT"] = previous
    end
  end

  def test_a_spec_compiles_again_when_a_file_it_imports_changes
    Dir.mktmpdir do |dir|
      counting = File.join(dir, "counting-quint")
      File.write(counting, "#!/bin/sh\necho \"$1\" >> #{dir}/ran\nexec #{QuintDriver::Quint.command} \"$@\"\n")
      File.chmod(0o755, counting)
      Dir.mkdir(File.join(dir, "lib"))
      constants = File.join(dir, "lib", "start.qnt")
      File.write(constants, "module start {\n  pure val START = 2\n}\n")
      File.write(File.join(dir, "lib", "shelf.qnt"), "module shelf {\n  import start.* from \"start\"\n  pure val FROM = START\n}\n")
      spec = File.join(dir, "countdown.qnt")
      File.write(spec, "module countdown {\n  import shelf.* from \"./lib/shelf\"\n  var n: int\n  action init = n' = FROM\n  action tick = n' = n - 1\n  action step = any { tick }\n}\n")
      previous, ENV["QUINT"] = ENV["QUINT"], counting
      start = lambda do
        QuintDriver::Quint.compile(spec, main: "countdown")["modules"].find { _1["name"] == "start" }["declarations"].first["expr"]["value"]
      end

      2.times { assert_equal 2, start.() }
      File.write(constants, "module start {\n  pure val START = 3\n}\n")
      assert_equal 3, start.(), "a file the spec imports through another one changed"
      assert_equal "compile\ncompile\n", File.read(File.join(dir, "ran"))
    ensure
      ENV["QUINT"] = previous
    end
  end

  # quint adds .qnt to every name an import gives, one that ends in .qnt too.
  def test_a_spec_compiles_again_when_the_file_an_import_ending_in_qnt_names_changes
    Dir.mktmpdir do |dir|
      imported = File.join(dir, "start.qnt.qnt")
      File.write(imported, "module start {\n  pure val START = 2\n}\n")
      File.write(File.join(dir, "start.qnt"), "module start {\n  pure val START = 9\n}\n")
      spec = File.join(dir, "countdown.qnt")
      File.write(spec, "module countdown {\n  import start.* from \"./start.qnt\"\n  var n: int\n  action init = n' = START\n  action step = n' = n - 1\n}\n")
      start = -> { QuintDriver::Quint.compile(spec, main: "countdown")["modules"].find { _1["name"] == "start" }["declarations"].first["expr"]["value"] }

      assert_equal 2, start.()
      File.write(imported, "module start {\n  pure val START = 3\n}\n")
      assert_equal 3, start.()
    end
  end

  def test_a_file_compiles_once_for_every_module_it_has
    Dir.mktmpdir do |dir|
      counting = File.join(dir, "counting-quint")
      File.write(counting, "#!/bin/sh\necho \"$1\" >> #{dir}/ran\nexec #{QuintDriver::Quint.command} \"$@\"\n")
      File.chmod(0o755, counting)
      spec = File.join(dir, "operators.qnt")
      File.write(spec, File.read(OPERATORS))
      previous, ENV["QUINT"] = ENV["QUINT"], counting

      first = QuintDriver::Spec.new(spec, main: "countdown")
      assert_equal %w[tick], first.rules("step").map(&:action)
      assert_equal %w[paint], QuintDriver::Spec.new(spec, main: "painting").rules("step").map(&:action)
      assert_equal %w[n init tick step], first.declarations.map { _1["name"] }, "a module compiled first reads like the others"
      assert_equal %w[painting operators], [ QuintDriver::Quint.compile(spec, main: "painting"), QuintDriver::Quint.compile(spec) ].map { _1["main"] }
      error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(spec, main: "nope") }
      assert_match(/no module is named nope/, error.message)
      assert_equal "compile\ncompile\n", File.read(File.join(dir, "ran")), "only the module the file lacks compiles again"
    ensure
      ENV["QUINT"] = previous
    end
  end

  def test_the_quint_command_is_the_one_quint_names_when_it_runs
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "fake-quint")
      File.write(fake, "#!/bin/sh\necho \"$1\" > #{dir}/ran\nexit 1\n")
      File.chmod(0o755, fake)
      previous, ENV["QUINT"] = ENV["QUINT"], fake

      assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(OPERATORS) }
      assert_equal "compile\n", File.read(File.join(dir, "ran"))
    ensure
      ENV["QUINT"] = previous
    end
  end

  def test_a_quint_command_that_is_not_installed_raises
    previous, ENV["QUINT"] = ENV["QUINT"], "quint-is-not-installed-here"

    error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(OPERATORS) }
    assert_equal "quint: cannot run `quint-is-not-installed-here`; set QUINT to the quint command " \
                 "(No such file or directory - quint-is-not-installed-here)", error.message
  ensure
    ENV["QUINT"] = previous
  end

  def test_compiling_a_spec_quint_rejects_raises_with_quints_reason
    error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(MISSING) }
    assert_match(/at the loading stage/, error.message)

    Dir.mktmpdir do |dir|
      invalid = File.join(dir, "invalid.qnt")
      File.write(invalid, "module invalid {\n  var n: int\n  action init = n = 1\n}\n")

      error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(invalid) }
      assert_equal "quint compile failed for #{invalid} at the parsing stage\n[QNT006] unexpected '=', did you mean '=='?", error.message

      twice = File.join(dir, "twice.qnt")
      File.write(twice, "module twice {\n  var n: int\n  action init = n' = m\n  action step = n' = k\n}\n")
      error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(twice) }
      assert_equal "quint compile failed for #{twice} at the parsing stage\n[QNT404] Name 'm' not found\n[QNT404] Name 'k' not found", error.message

      mistyped = File.join(dir, "mistyped.qnt")
      File.write(mistyped, "module mistyped {\n  var n: int\n  action init = n' = \"one\"\n}\n")

      error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(mistyped) }
      assert_match(/at the typechecking stage/, error.message)
      refute_match(/no module is named/, error.message)

      # A flat compile compiles the modules as the file has them first, so it fails with the same reasons.
      { invalid => /unexpected '='/, mistyped => /at the typechecking stage\n\[QNT000\] Couldn.t unify int and str/ }.each do |path, reason|
        error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(path, main: File.basename(path, ".qnt"), flat: true) }
        assert_match(reason, error.message)
      end
    end
  end

  def test_with_quint_set_its_failure_is_reported_as_it_printed
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "fake-quint")
      File.write(fake, "#!/bin/sh\necho 'npm error code E404'\nexit 1\n")
      File.chmod(0o755, fake)
      previous, ENV["QUINT"] = ENV["QUINT"], fake

      error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(OPERATORS) }
      assert_match(/\Aquint compile failed for .* at the start stage\nnpm error code E404\z/, error.message)
    ensure
      ENV["QUINT"] = previous
    end
  end

  def test_simulating_a_spec_quint_rejects_raises
    assert_raises(QuintDriver::QuintFailed) do
      QuintDriver::Quint.simulate(MISSING, traces: 1, max_steps: 1, seed: "1") { flunk "no trace for a missing spec" }
    end
  end

  def test_a_spec_that_names_no_module_of_its_file_lists_the_modules_it_has
    error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Spec.new(OPERATORS, main: "nope") }

    assert_match(/no module is named nope; .*operators\.qnt has operators, unsupported, countdown, painting, unassigned, pairing, approval\z/, error.message, "the modules in the order of the file")
  end

  def test_compiling_a_file_with_no_module_named_after_it_lists_the_modules_it_has
    Dir.mktmpdir do |dir|
      several = File.join(dir, "several.qnt")
      File.write(several, File.read(OPERATORS))

      error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(several) }
      assert_match(/no module is named several; .*several\.qnt has operators, unsupported, countdown, painting/, error.message)
    end
  end

  def test_without_quint_set_a_failed_fetch_says_npx_could_not_fetch_quint
    Dir.mktmpdir do |dir|
      previous = ENV.to_h.slice("QUINT", "npm_config_registry", "npm_config_cache", "npm_config_fetch_retries")
      ENV.delete("QUINT")
      ENV.update("npm_config_registry" => "http://127.0.0.1:9/", "npm_config_cache" => dir, "npm_config_fetch_retries" => "0")

      # A copy at a path of its own, because a test that ran earlier with
      # QUINT unset leaves OPERATORS compiled under this very command.
      copy = File.join(dir, "operators.qnt")
      File.write(copy, File.read(OPERATORS))

      error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(copy) }
      assert_match(/\Aquint: QUINT is unset, and `npx --yes @informalsystems\/quint@0\.33\.0` could not fetch quint/, error.message)
      assert_match(/set QUINT/, error.message)
      refute_match(/^npm error/, error.message)
    ensure
      %w[QUINT npm_config_registry npm_config_cache npm_config_fetch_retries].each { ENV[_1] = previous[_1] }
    end
  end

  private
    # Each step of every trace, from specs that cover each kind of value.
    def simulated_states
      [ [ LoansDriver::SPEC, nil, 200, 30, "7" ], [ OPERATORS, nil, 100, 20, "3" ],
        [ OPERATORS, "countdown", 3, 2, "1" ], [ OPERATORS, "painting", 20, 10, "5" ] ].map do |path, main, traces, max_steps, seed|
        states = []
        QuintDriver::Quint.simulate(path, main:, traces:, max_steps:, seed:) do |trace|
          states << QuintDriver::Trace.steps(trace).map(&:to_a)
        end
        states
      end
    end

    # The quint subcommands the block ran, such as "compile" and "run".
    def quint_subcommands
      Dir.mktmpdir do |dir|
        counting = File.join(dir, "counting-quint")
        File.write(counting, "#!/bin/sh\necho \"$1\" >> #{dir}/ran\nexec #{QuintDriver::Quint.command} \"$@\"\n")
        File.chmod(0o755, counting)
        with_env("QUINT" => counting) { yield }
        File.exist?(File.join(dir, "ran")) ? File.readlines(File.join(dir, "ran"), chomp: true) : []
      end
    end

    def with_env(values)
      previous = ENV.to_h.slice(*values.keys)
      ENV.update(values)
      yield
    ensure
      values.each_key { ENV[_1] = previous[_1] }
    end
end
