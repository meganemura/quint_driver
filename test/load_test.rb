require_relative "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

class LoadTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)
  LOANS = File.expand_path("../examples/loans/loans", __dir__)

  def test_trace_replay_and_the_model_run_where_hegel_cannot_be_loaded
    output, status = without_hegel(<<~RUBY)
      require "quint_driver"
      require #{LOANS.inspect}
      count = 0
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 5, max_steps: 10, seed: "1") do |path|
        QuintDriver::Trace.replay(path, LoansDriver.new)
        QuintDriver::Trace.replay(path, LoansDriver.spec.model)
        count += 1
      end
      print count
    RUBY

    assert status.success?, output
    assert_equal "5", output
  end

  def test_the_hegel_adapter_is_what_loads_hegel
    output, status = without_hegel('require "quint_driver/hegel"')

    refute status.success?
    assert_match(/hegel is hidden/, output)
  end

  private
    # A hegel.rb ahead of every gem on the load path stands in for a missing hegeltest.
    def without_hegel(script)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "hegel.rb"), 'raise LoadError, "hegel is hidden"')
        Open3.capture2e(RbConfig.ruby, "-I", dir, "-I", LIB, "-e", script)
      end
    end
end
