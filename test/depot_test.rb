# Runs the specs of the depot, the Rails app in test/fixture/depot, on the
# app as committed and on the app with its fixed.patch applied. The app's
# spec/quint hunts the way an agent would in an app of its own: it replays
# the traces Quint aims at each expectation of depot.qnt, and runs the Hegel
# machine with the same expectations. The app as committed has four bugs
# planted, one behind each expectation, which PLANTED lists. The specs run
# with the fixture's own gems, so the test skips until `bundle install` has
# run in test/fixture/depot, and QUINT_DRIVER_DEPOT=required makes that skip a
# failure.
require_relative "test_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

class DepotTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FIXTURE = File.join(ROOT, "test/fixture/depot")

  # Each planted bug, by the expectation of depot.qnt that it breaks.
  PLANTED = {
    "taken_compartment_has_live_code" =>
      "AssignmentsController#create rescues the locker controller's time-out inside its transaction, " \
      "so the assignment commits with no code live",
    "free_compartment_has_no_code" =>
      "ReleasesController#create rescues it inside its transaction too, " \
      "so the compartment is free while its old code still opens the door",
    "done_row_stays_done" =>
      "IntakeJob#perform goes through every row again when it is retried, " \
      "so a row that was done fails the second time and is overwritten",
    "finished_job_leaves_no_row_pending" =>
      "IntakeJob#perform ignores that a row whose parcel was withdrawn does not save, " \
      "so the row stays pending after the job has finished"
  }.freeze

  REPLAY = "does what the spec says on every trace Quint writes"
  MACHINE = "keeps every expectation on the sequences Hegel chooses"
  PINNED = "keeps free_compartment_has_no_code when a release times out"

  # One rspec run of the app: its examples as rspec's JSON report holds them,
  # and what rspec printed.
  Run = Data.define(:examples, :printed) do
    def example(description)
      examples.find { _1["description"] == description } or raise "rspec ran no example \"#{description}\"\n#{printed}"
    end

    def failed = examples.select { _1["status"] == "failed" }
  end

  # The depot runs with its own bundle and on its own SQLite file, whatever
  # bundle this test runs in and whatever database the shell names.
  def self.sh(*command, chdir:)
    env = (defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h).except("DATABASE_URL").merge("RAILS_ENV" => "test")
    Open3.capture2e(env, *command, chdir:, unsetenv_others: true)
  end

  def self.rspec(app)
    printed, = sh("bundle", "exec", "rspec", "--format", "progress", "--format", "json", "--out", "examples.json", chdir: app)
    report = File.join(app, "examples.json")
    Run.new(File.exist?(report) ? JSON.parse(File.read(report)).fetch("examples") : [], printed)
  end

  # The run of the app as committed and the run of the app with fixed.patch
  # applied, made once for every test here, or the reason the depot cannot
  # run. Each is a copy, so a run leaves the fixture as it was.
  def self.runs
    @runs ||=
      if RUBY_VERSION < "3.4"
        "the depot's specs load hegeltest, which needs Ruby 3.4"
      else
        Dir.mktmpdir do |folder|
          planted, fixed = File.join(folder, "planted"), File.join(folder, "fixed")
          FileUtils.mkdir(planted)
          (Dir.children(FIXTURE) - %w[log storage tmp]).each { FileUtils.cp_r(File.join(FIXTURE, _1), planted) }
          gemfile = File.join(planted, "Gemfile")
          from_this_checkout = File.read(gemfile).sub!('path: "../../.."') { "path: #{ROOT.inspect}" }
          raise "#{gemfile} does not load quint_driver from ../../.." unless from_this_checkout

          File.write(gemfile, from_this_checkout)
          # Without --local, a machine that lacks the gems would download Rails in the middle of the suite.
          printed, status = sh("bundle", "install", "--local", chdir: planted)
          next "the depot's gems are not installed; run `bundle install` in test/fixture/depot\n#{printed}" unless status.success?

          FileUtils.cp_r(planted, fixed)
          printed, status = sh("patch", "-p1", "-i", "fixed.patch", chdir: fixed)
          raise "fixed.patch does not apply to the depot:\n#{printed}" unless status.success?

          [ planted, fixed ].map { |app| Thread.new { rspec(app) } }.map(&:value)
        end
      end
  end

  def setup
    runs = self.class.runs
    if runs.is_a?(String)
      flunk "QUINT_DRIVER_DEPOT=required, and #{runs}" if ENV["QUINT_DRIVER_DEPOT"] == "required"
      skip runs
    end
    @planted, @fixed = runs
  end

  def hunt(expectation) = "keeps #{expectation} on the traces Quint aims at it"

  def test_the_hunt_raises_violated_for_each_planted_bug_and_nothing_mismatches
    PLANTED.each do |expectation, bug|
      failure = @planted.example(hunt(expectation))["exception"]
      assert failure, "the hunt kept #{expectation}, although #{bug}\n#{@planted.printed}"
      assert_equal "QuintDriver::Violated", failure["class"], failure["message"]
      assert_includes failure["message"], "the system agreed with the spec at every step, and the expectation `#{expectation}` does not hold"
    end
    found_a_bug = PLANTED.keys.map { hunt(_1) } << MACHINE << PINNED
    assert_equal found_a_bug.sort, @planted.failed.map { _1["description"] }.sort, @planted.printed
    assert_equal [ "QuintDriver::Violated" ], @planted.failed.map { _1.dig("exception", "class") }.uniq, @planted.printed
  end

  # The app follows every trace of the spec, so only a replay that names an
  # expectation can tell that the app has a bug.
  def test_a_replay_that_names_no_expectation_passes_on_the_planted_app
    assert_equal "passed", @planted.example(REPLAY)["status"], @planted.printed
  end

  # The steps a trace's Violated printed, pasted into replay_steps, raise the
  # same Violated, apart from the trace line.
  def test_the_pasted_steps_of_a_violated_raise_it_again
    traced = @planted.example(hunt("free_compartment_has_no_code")).dig("exception", "message")
    pinned = @planted.example(PINNED).dig("exception", "message")
    assert_equal traced.sub(/\ntrace: .*\z/, ""), pinned
  end

  def test_the_machine_raises_violated_and_shrinks_it_to_one_move
    failure = @planted.example(MACHINE)["exception"]
    assert failure, "the machine kept every expectation\n#{@planted.printed}"
    assert_equal "QuintDriver::Violated", failure["class"], failure["message"]
    assert_includes failure["message"], "the expectation `taken_compartment_has_live_code` does not hold after step 1 `assignParcel`"
  end

  # The hunt sections of the skill and of both READMEs quote the depot: each
  # quint or ruby block is a part of a file the depot runs, and each text
  # block is the message the planted app raised, without its trace line.
  def test_the_docs_quote_the_depot_and_the_violated_it_raises
    hunt = %w[depot_spec.rb depot.qnt depot_driver.rb].sum("") { File.read(File.join(FIXTURE, "spec/quint", _1)) }
    { "skills/quint_driver/SKILL.md" => "## Hunt for bugs", "README.md" => "## Hunt for bugs", "README.ja.md" => "## バグを探す" }.each do |doc, heading|
      section = File.read(File.join(ROOT, doc), encoding: "UTF-8")[/^#{heading}\n(.*?)(?=^## )/m, 1]
      assert section, "#{doc} has no #{heading} section"
      blocks = section.scan(/^```(\w+)\n(.*?)^```$/m)
      code, text = blocks.partition { |kind, _| kind != "text" }
      refute_empty code, doc
      code.each { |_, body| assert_includes hunt, body, "#{doc} quotes a block the depot does not run" }
      text.each do |_, body|
        expectation = body[/the expectation `(\w+)`/, 1]
        message = @planted.example(hunt(expectation)).dig("exception", "message")
        assert_equal body, "#{message.sub(/\ntrace: .*\z/, '')}\n", "#{doc} pastes a Violated the planted app did not raise"
      end
    end
  end

  def test_every_example_passes_once_fixed_patch_is_applied
    assert_equal @planted.examples.map { _1["full_description"] }, @fixed.examples.map { _1["full_description"] }, @fixed.printed
    assert_empty @fixed.examples.reject { _1["status"] == "passed" }.map { _1["full_description"] }, @fixed.printed
  end
end
