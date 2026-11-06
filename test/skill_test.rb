# Runs the skill's Rails example "A choice the code leaves to the database",
# so the skill cannot drift from what the gem does. It runs only when
# QUINT_DRIVER_SKILL_APP names a Rails app to copy, because the gem's own
# bundle holds no Rails. The run uses the app's database, so DATABASE_URL
# moves it to PostgreSQL without a PostgreSQL requirement in CI.
require_relative "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class SkillTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ORDER_SECTION = "A choice the code leaves to the database"
  SPEC = "spec/quint/slots_spec.rb"

  def section(heading)
    File.read(File.join(ROOT, "skills/quint_driver/SKILL.md"), encoding: "UTF-8")[/^### #{heading}\n(.*?)(?=^##)/m, 1]
  end

  def fences(text) = text.scan(/^```(\w+)\n(.*?)^```\n/m)

  # rspec indents a failure message, so lines compare without their indent.
  def lines(text) = text.lines.map(&:strip).reject(&:empty?)

  # A comment that names a file starts it, and one block can hold two files.
  def files(blocks)
    blocks.each_with_object({}) do |(_kind, body), found|
      path = nil
      body.each_line do |line|
        named = line[%r{\A(?:#|//) ([\w/]+\.(?:rb|qnt))\b}, 1]
        found[path = named] = +"" if named
        found[path] << line if path
      end
    end
  end

  def unbundled(&run) = defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call

  def run_in(folder, command) = unbundled { Open3.capture2e("bash", "-c", command, chdir: folder) }

  # The app is copied, so the run leaves it as it was. Its Gemfile must not
  # name quint_driver: the test adds this checkout.
  def test_the_order_example_replays_and_fails_as_the_skill_shows_without_the_wrap
    app = ENV["QUINT_DRIVER_SKILL_APP"]
    skip "set QUINT_DRIVER_SKILL_APP to a Rails app with rspec-rails, Item, and the items and session routes" unless app

    blocks = fences(section(ORDER_SECTION))
    Dir.mktmpdir do |folder|
      FileUtils.cp_r(File.join(app, "."), folder)
      File.write(File.join(folder, "Gemfile"), "\ngem \"quint_driver\", path: #{ROOT.inspect}\n", mode: "a")
      files(blocks).each do |path, body|
        FileUtils.mkdir_p(File.dirname(File.join(folder, path)))
        File.write(File.join(folder, path), body)
      end
      printed, status = run_in(folder, "bundle install --prefer-local && RAILS_ENV=test bin/rails db:prepare")
      assert status.success?, printed

      printed, status = run_in(folder, "bundle exec rspec #{SPEC}")
      assert status.success?, printed

      spec = File.join(folder, SPEC)
      unwrapped = File.read(spec).sub(/^  before do\n.*?^  end\n\n/m, "")
      refute_equal File.read(spec), unwrapped, "the spec wraps the reader in before"
      File.write(spec, unwrapped)
      printed, status = run_in(folder, "bundle exec rspec #{SPEC}")
      refute status.success?, printed
      failure = lines(blocks.find { |kind, _| kind == "text" }.last)
      assert lines(printed).each_cons(failure.size).include?(failure), printed
    end
  end
end
