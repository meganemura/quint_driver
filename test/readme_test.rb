# Runs the README's examples, so the README cannot drift from what the gem
# does. "Try it without an app" runs in an empty folder on every run. The
# Rails quick start runs only when QUINT_DRIVER_README_APP names a Rails app
# to copy, because the gem's own bundle holds no Rails.
require_relative "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class ReadmeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RAILS_QUICK_START = "Quick start in your Rails app"
  RAILS_OUTPUT = "What you will see"
  WITHOUT_AN_APP = "Try it without an app"

  Block = Data.define(:script, :output)

  def sections(readme) = File.read(File.join(ROOT, readme), encoding: "UTF-8").split(/^## /)

  # README.ja.md keeps the sections in the order of README.md, under headings
  # of its own, so a section is found by its English heading's position.
  def section(heading, readme = "README.md")
    position = sections("README.md").index { _1.start_with?("#{heading}\n") }
    sections(readme).fetch(position)
  end

  def fences(text) = text.scan(/^```(\w+)\n(.*?)^```\n/m)

  # Timings change on every run, rspec ends with a blank line, and Ruby 3.3
  # quotes a backtrace label with a backtick and names a method without its
  # class, where Ruby 3.4 writes RSpec::ExampleGroups::Loan#rolled_back.
  def steady(output)
    output.gsub(/^Finished in .*$/, "Finished").tr("`", "'").gsub(/(?<=in '|block in )RSpec::ExampleGroups::\w+#/, "").rstrip
  end

  def unbundled(&run) = defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call

  def test_the_japanese_readme_shows_the_same_examples
    [ RAILS_QUICK_START, RAILS_OUTPUT, WITHOUT_AN_APP ].each do |heading|
      assert_equal fences(section(heading)), fences(section(heading, "README.ja.md")), heading
    end
  end

  def test_the_example_without_an_app_prints_what_the_readme_shows
    blocks = fences(section(WITHOUT_AN_APP)).drop(1).each_with_object([]) do |(kind, body), found|
      if kind == "sh" then found << Block.new(body, nil)
      else found[-1] = found.last.with(output: body)
      end
    end
    assert_equal 3, blocks.size, "the example writes, runs, and breaks"
    env = { "RUBYLIB" => [ File.join(ROOT, "lib"), ENV["RUBYLIB"] ].compact.join(File::PATH_SEPARATOR) }
    Dir.mktmpdir do |folder|
      blocks.each do |block|
        printed, status = Open3.capture2e(env, "bash", "-c", block.script, chdir: folder)
        if block.output
          assert_equal steady(block.output), steady(printed), block.script
        else
          assert status.success?, printed
        end
      end
    end
  end

  # The app is copied, so the run leaves it as it was. Its Gemfile must not
  # name quint_driver yet: the quick start adds the gem built from this checkout.
  def test_the_rails_quick_start_prints_what_the_readme_shows
    app = ENV["QUINT_DRIVER_README_APP"]
    skip "set QUINT_DRIVER_README_APP to a Rails app with rspec-rails, Borrower, and Loan" unless app

    Dir.mktmpdir do |folder|
      FileUtils.cp_r(File.join(app, "."), folder)
      FileUtils.mkdir_p(File.join(folder, "vendor/cache"))
      run_in(ROOT, "gem build quint_driver.gemspec -o #{File.join(folder, "vendor/cache/quint_driver-#{QuintDriver::VERSION}.gem")}")
      printed = nil
      blocks = fences(section(RAILS_QUICK_START)) + fences(section(RAILS_OUTPUT))
      blocks.each do |kind, body|
        path = body[%r{\A(?:#|//) (\S+)\n}, 1]
        if path == "Gemfile"
          File.write(File.join(folder, path), "\n#{body}", mode: "a")
        elsif path
          FileUtils.mkdir_p(File.dirname(File.join(folder, path)))
          File.write(File.join(folder, path), body)
        elsif kind == "sh" && body.include?("bundle install")
          run_in(folder, "bundle install --prefer-local")
        elsif kind == "sh"
          printed = unbundled { Open3.capture2e("bash", "-c", body, chdir: folder) }.first
        elsif kind == "text"
          assert_equal steady(body), steady(printed)
        elsif kind == "diff"
          apply(body, folder)
        end
      end
    end
  end

  def run_in(folder, command)
    printed, status = unbundled { Open3.capture2e("bash", "-c", command, chdir: folder) }
    assert status.success?, "#{command}\n#{printed}"
  end

  def apply(diff, folder)
    path = File.join(folder, diff[%r{^\+\+\+ b/(\S+)$}, 1])
    hunk = diff.lines.grep_v(/^(---|\+\+\+) /)
    before = hunk.reject { _1.start_with?("+") }.map { _1[1..] }.join
    after = hunk.reject { _1.start_with?("-") }.map { _1[1..] }.join
    text = File.read(path)
    assert_equal 1, text.scan(before).size, "the diff's lines appear once in #{path}"
    File.write(path, text.sub(before, after))
  end
end
