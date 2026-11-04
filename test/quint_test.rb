require_relative "test_helper"
require "tmpdir"

class QuintTest < Minitest::Test
  MISSING = File.expand_path("missing.qnt", __dir__)
  RECORDED = File.expand_path("recorded.qnt", __dir__)
  OPERATORS = File.expand_path("operators.qnt", __dir__)

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
      File.write(other, "#!/bin/sh\ncat > /dev/null\necho '{\"traces\": []}'\n")
      File.chmod(0o755, other)

      error = with_env("QUINT_EVALUATOR" => other) do
        assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.simulate(OPERATORS, main: "countdown", traces: 1, max_steps: 1, seed: "1") { flunk } }
      end
      assert_match(/answered in a format quint_driver does not read; it reads the v0\.7\.0 evaluator/, error.message)
      assert_match(/QUINT_EVALUATOR/, error.message)
    end
  end

  def test_an_evaluator_that_fails_or_reports_an_error_raises_with_its_reason
    Dir.mktmpdir do |dir|
      { "echo 'evaluator crashed' >&2; exit 1" => /failed:\nevaluator crashed/,
        %(echo '{"status": "error", "errors": [{"code": "QNT503", "message": "division by zero"}], "bestTraces": []}') => /\Aquint run failed:\nError \[QNT503\]: division by zero\z/ }
        .each do |script, reason|
          evaluator = File.join(dir, "evaluator")
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
    assert_match(/seed/, error.message)
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

  def test_an_evaluator_that_is_not_installed_raises
    error = with_env("QUINT_EVALUATOR" => "/nonexistent/quint_evaluator") do
      assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.simulate(OPERATORS, main: "countdown", traces: 1, max_steps: 1, seed: "1") { flunk } }
    end
    assert_match(%r{\Aquint: cannot run the Rust evaluator /nonexistent/quint_evaluator; set QUINT_EVALUATOR}, error.message)
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
    assert_match(/set QUINT/, error.message)
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
      assert_match(/unexpected '='/, error.message)

      mistyped = File.join(dir, "mistyped.qnt")
      File.write(mistyped, "module mistyped {\n  var n: int\n  action init = n' = \"one\"\n}\n")

      error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(mistyped) }
      assert_match(/at the typechecking stage/, error.message)
      refute_match(/no module is named/, error.message)
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

    assert_match(/no module is named nope; .*operators\.qnt has operators, unsupported, countdown, painting/, error.message)
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

      error = assert_raises(QuintDriver::QuintFailed) { QuintDriver::Quint.compile(OPERATORS) }
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

    def with_env(values)
      previous = ENV.to_h.slice(*values.keys)
      ENV.update(values)
      yield
    ensure
      values.each_key { ENV[_1] = previous[_1] }
    end
end
