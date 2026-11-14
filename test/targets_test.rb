require_relative "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

class TargetsTest < Minitest::Test
  COMMAND = File.expand_path("../exe/quint_driver", __dir__)
  ROOT = File.expand_path("..", __dir__)

  # The depot's four planted bugs sit in the three files ranked first.
  def test_the_depot_s_planted_bugs_lead_the_ranking_and_the_skill_shows_it
    output, status = Open3.capture2e(RbConfig.ruby, COMMAND, "targets", "test/fixture/depot", "--top", "3", chdir: ROOT)

    assert status.success?, output
    assert_equal %w[app/jobs/intake_job.rb app/controllers/assignments_controller.rb app/controllers/releases_controller.rb],
                 output.scan(/^(\S+\.rb):/).flatten
    skill = File.read(File.join(ROOT, "skills/quint_driver/SKILL.md"))
    assert_includes skill, "```sh\nbundle exec quint_driver targets test/fixture/depot --top 3\n```\n\n```text\n#{output}```\n"
  end

  def test_a_call_that_drops_what_a_method_that_can_fail_answers_is_a_hit
    Dir.mktmpdir do |app|
      write(app, "app/services/hold.rb", <<~RUBY)
        class Hold
          def self.place(rental)
            rental.update(held: true)
          end
        end
      RUBY
      write(app, "app/services/start.rb", <<~RUBY)
        class Start
          # rescue here is a comment, not a hit
          def call(rental)
            Hold.place(rental)
            kept = Hold.place(rental)
          end
        end
      RUBY
      write(app, "spec/start_spec.rb", "Rental.transaction do\nend\n")

      hits = QuintDriver::Targets.scan(app).map { [ _1.kind, _1.file, _1.line ] }

      assert_equal [ [ "unchecked-save", "app/services/hold.rb", 3 ], [ "dropped-result", "app/services/start.rb", 4 ] ], hits
    end
  end

  def test_an_app_with_no_hit_says_so
    Dir.mktmpdir do |app|
      write(app, "app/models/note.rb", "class Note\nend\n")

      assert_equal "No hit under #{app}/app or #{app}/lib.\n", QuintDriver::Targets.report(app)
    end
  end

  private
    def write(root, path, text)
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), text)
    end
end
