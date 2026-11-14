require_relative "test_helper"
require "open3"
require "rbconfig"

class OutlineTest < Minitest::Test
  COMMAND = File.expand_path("../exe/quint_driver", __dir__)
  DEPOT = File.expand_path("fixture/depot/spec/quint/depot.qnt", __dir__)
  ANONYMOUS = File.expand_path("anonymous.qnt", __dir__)

  def test_the_outline_lists_each_action_with_its_picks_and_each_variable_with_its_shape
    output, status = Open3.capture2e(RbConfig.ruby, COMMAND, "outline", DEPOT)

    assert status.success?, output
    assert_equal <<~RUBY, output
      # A driver for the module depot, whose step action is step.
      # Expectations, for invariants: or violate:
      #   taken_compartment_has_live_code
      #   free_compartment_has_no_code
      #   done_row_stays_done
      #   finished_job_leaves_no_row_pending
      class DepotDriver
        def step(action, picks)
          case action
          when "init"
          when "assignParcel" # picks["p"]: String, picks["offline"]: Integer
          when "release" # picks["p"]: String, picks["offline"]: Integer
          when "withdraw" # picks["p"]: String
          when "takeIn"
          when "runJob" # picks["offline"]: Integer
          end
        end

        # A variable the system does not keep, such as a pick the spec
        # remembers, goes in ignore: instead of here.
        def state
          {
            "place" => nil, # Hash of String => "Waiting", ["In", Integer], "Collected" or "Withdrawn"
            "live" => nil, # Set of Integer
            "row" => nil, # Hash of String => String
            "intake" => nil, # String
            "everDone" => nil, # Set of String
          }
        end
      end
    RUBY
  end

  # The skeleton is Ruby, and each name in it is one a replay reads: a
  # driver that keeps it as it is fails at init on the variables it reports
  # as nil, and on no name it left out.
  def test_a_driver_kept_as_the_outline_wrote_it_fails_on_its_values
    output, = Open3.capture2e(RbConfig.ruby, COMMAND, "outline", LoansDriver::SPEC)
    driver = Module.new.module_eval(output + "\nLoansDriver").new

    error = assert_raises(QuintDriver::Mismatch) do
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 1, max_steps: 1, seed: "1") { QuintDriver::Trace.replay(_1, driver) }
    end
    assert_match(/after step 0 `init`/, error.message)
    assert_includes error.message, %(holder: trace {"b1" => "", "b2" => "", "b3" => ""}, driver nil\n  outcome: trace "Done", driver nil\nsteps:)  end

  def test_the_skill_shows_the_outline_the_command_prints
    output, status = Open3.capture2e(RbConfig.ruby, COMMAND, "outline", "examples/loans/loans.qnt", chdir: File.expand_path("..", __dir__))

    assert status.success?, output
    skill = File.read(File.expand_path("../skills/quint_driver/SKILL.md", __dir__))
    assert_includes skill, "```sh\nbundle exec quint_driver outline examples/loans/loans.qnt\n```\n\n```ruby\n#{output}```\n"
  end

  def test_a_step_no_driver_can_run_exits_1_with_the_reason
    output, status = Open3.capture2e(RbConfig.ruby, COMMAND, "outline", ANONYMOUS)

    assert_equal 1, status.exitstatus
    assert_equal "quint: step assigns n' in an arm that names no action; name every action in step\n", output
  end

  # Quint lets a module name start with an underscore, which splits into an
  # empty first word.
  def test_a_module_name_that_starts_with_an_underscore_names_the_driver_class
    Dir.mktmpdir do |dir|
      path = File.join(dir, "_counter.qnt")
      File.write(path, <<~QUINT)
        module _counter {
          var n: int
          action init = n' = 0
          action tick = n' = n + 1
          action step = any { tick }
        }
      QUINT

      assert_includes QuintDriver::Spec.new(path).outline, "\nclass CounterDriver\n"
    end
  end

  def test_a_spec_with_no_expectation_says_to_write_one
    output, status = Open3.capture2e(RbConfig.ruby, COMMAND, "outline", File.expand_path("recorded.qnt", __dir__))

    assert status.success?, output
    assert_includes output, "#   none yet: write what the operator expects as boolean vals\n"
  end
end
