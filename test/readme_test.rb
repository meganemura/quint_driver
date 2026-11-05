# Runs the README's quick start in an empty folder, so the README cannot
# drift from what the gem does: every sh block after the install block, in
# order, each compared with the text block that follows it.
require_relative "test_helper"
require "open3"
require "tmpdir"

class ReadmeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  Block = Data.define(:script, :output)

  # The first section of a README is the quick start, and its first block installs.
  def quick_start(readme)
    section = File.read(File.join(ROOT, readme), encoding: "UTF-8").split(/^## /)[1]
    fences = section.scan(/^```(\w+)\n(.*?)^```\n/m).drop(1)
    fences.each_with_object([]) do |(kind, body), blocks|
      if kind == "sh" then blocks << Block.new(body, nil)
      else blocks[-1] = blocks.last.with(output: body)
      end
    end
  end

  # Timings change on every run, rspec ends with a blank line, and Ruby 3.3 quotes
  # a backtrace label with a backtick.
  def steady(output) = output.gsub(/^Finished in .*$/, "Finished").tr("`", "'").rstrip

  def test_the_japanese_readme_shows_the_same_quick_start
    assert_equal quick_start("README.md"), quick_start("README.ja.md")
  end

  def test_the_quick_start_prints_what_the_readme_shows
    blocks = quick_start("README.md")
    assert_equal 3, blocks.size, "the quick start writes, runs, and breaks"
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
end
