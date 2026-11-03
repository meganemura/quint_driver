require_relative "test_helper"

class QuintTest < Minitest::Test
  MISSING = File.expand_path("missing.qnt", __dir__)

  def test_compiling_a_spec_quint_rejects_raises
    assert_raises(RuntimeError) { QuintConnectHegel::Quint.compile(MISSING) }
  end

  def test_simulating_a_spec_quint_rejects_raises
    assert_raises(RuntimeError) do
      QuintConnectHegel::Quint.simulate(MISSING, traces: 1, max_steps: 1, seed: "1") { flunk "no trace for a missing spec" }
    end
  end
end
