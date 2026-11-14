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

  def test_an_app_with_no_hit_says_so_and_what_to_read_instead
    Dir.mktmpdir do |app|
      write(app, "app/models/note.rb", "class Note\nend\n")

      assert_equal <<~TEXT, QuintDriver::Targets.report(app)
        No hit under #{app}/app or #{app}/lib.
        That says no line matched, not that a hunt cannot pay here. List the entry points (controllers, jobs, rake tasks), ask which of them write the same rows, and read where one of them calls a service that can fail.
      TEXT
    end
  end

  # Comments, strings, heredocs, regexps and =begin blocks hold words such
  # as save and rescue that are no code, and a save the line itself reads is
  # checked.
  def test_text_that_is_no_code_and_a_save_the_line_reads_are_no_hits
    Dir.mktmpdir do |app|
      write(app, "app/models/report.rb", <<~'RUBY')
        =begin
        user.save
        rescue
        =end
        class Report
          SQL = <<~TEXT
            update reports set seen = 1
          TEXT
          PATTERN = /\bsave\b/
          def run
            log "rescue me"
            ok # return false when the rate is off
            user.save or raise "no"
            user.save || raise("no")
          end
        end
      RUBY

      assert_empty QuintDriver::Targets.scan(app)
    end
  end

  # The method a line sits in is the def that holds it: a save after a def
  # has ended belongs to no method, so a call of that def drops nothing.
  # And a method named as many others are, such as call, counts only where
  # its class is named.
  def test_a_dropped_result_needs_the_def_that_holds_the_save_and_a_common_name_its_class
    Dir.mktmpdir do |app|
      write(app, "app/models/a.rb", "class A\n  def one\n  end\n  CONST = 1\n  update\nend\n")
      write(app, "app/services/charge.rb", "class Charge\n  def call\n    @order.save\n  end\nend\n")
      write(app, "app/controllers/orders_controller.rb", <<~RUBY)
        class OrdersController
          def create
            one
            Notify.call(user)
            Charge.new(order).call
          end
        end
      RUBY

      hits = QuintDriver::Targets.scan(app).map { [ _1.kind, _1.file, _1.line ] }

      assert_equal [ [ "unchecked-save", "app/models/a.rb", 5 ], [ "unchecked-save", "app/services/charge.rb", 3 ],
                     [ "dropped-result", "app/controllers/orders_controller.rb", 5 ] ], hits
    end
  end

  # A check of what the app stored, then a write with no lock, is where two
  # requests can both pass the check. A check of the arguments alone, or a
  # method that takes a lock, is not.
  def test_a_write_after_a_check_of_stored_state_with_no_lock_is_a_hit
    Dir.mktmpdir do |app|
      write(app, "app/models/loan.rb", <<~RUBY)
        class Loan
          def approve(officer)
            return :already if state == "approved"
            return :over if borrower.approved_cents + amount_cents > borrower.limit_cents

            update!(state: "approved", approved_by: officer.fetch(:name))
          end

          def rename(name)
            return :blank if name.empty?

            update!(name: name)
          end

          def close
            with_lock do
              return if state == "closed"

              update!(state: "closed")
            end
          end
        end
      RUBY
      write(app, "app/controllers/shelves_controller.rb", <<~RUBY)
        class ShelvesController
          def create
            shelf = Shelf.free.first
            return head(:conflict) unless shelf

            loan.place_on(shelf)
          end
        end
      RUBY
      write(app, "app/models/book.rb", "class Book\n  def place_on(shelf)\n    update!(shelf:)\n  end\nend\n")

      hits = QuintDriver::Targets.scan(app).select { _1.kind == "check-then-write" }.map { [ _1.file, _1.line ] }

      assert_equal [ [ "app/controllers/shelves_controller.rb", 6 ], [ "app/models/loan.rb", 6 ] ], hits
    end
  end

  def test_a_directory_named_like_a_ruby_file_is_skipped
    Dir.mktmpdir do |app|
      write(app, "app/a.rb/keep", "")

      assert_empty QuintDriver::Targets.scan(app)
    end
  end

  def test_the_command_refuses_a_top_below_one_and_a_directory_that_is_not_there
    output, status = Open3.capture2e(RbConfig.ruby, COMMAND, "targets", "test/fixture/depot", "--top", "0", chdir: ROOT)
    refute status.success?
    assert_equal "quint: top takes 1 or more, not 0\n", output

    output, status = Open3.capture2e(RbConfig.ruby, COMMAND, "targets", "no/such/app", chdir: ROOT)
    refute status.success?
    assert_equal "quint: no directory no/such/app\n", output
  end

  private
    def write(root, path, text)
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), text)
    end
end
