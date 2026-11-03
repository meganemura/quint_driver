require_relative "test_helper"
require "tmpdir"

class QuintTest < Minitest::Test
  MISSING = File.expand_path("missing.qnt", __dir__)
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
end
