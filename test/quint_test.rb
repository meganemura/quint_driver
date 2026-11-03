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

  def test_the_quint_command_is_the_one_quint_names_when_it_runs
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "fake-quint")
      File.write(fake, "#!/bin/sh\necho \"$1\" > #{dir}/ran\nexit 1\n")
      File.chmod(0o755, fake)
      previous, ENV["QUINT"] = ENV["QUINT"], fake

      assert_raises(RuntimeError) { QuintDriver::Quint.compile(OPERATORS) }
      assert_equal "compile\n", File.read(File.join(dir, "ran"))
    ensure
      ENV["QUINT"] = previous
    end
  end

  def test_compiling_a_spec_quint_rejects_raises
    assert_raises(RuntimeError) { QuintDriver::Quint.compile(MISSING) }
  end

  def test_simulating_a_spec_quint_rejects_raises
    assert_raises(RuntimeError) do
      QuintDriver::Quint.simulate(MISSING, traces: 1, max_steps: 1, seed: "1") { flunk "no trace for a missing spec" }
    end
  end
end
