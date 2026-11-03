require "json"
require "open3"
require "tmpdir"

module QuintConnectHegel
  # The `quint` command line: the one place this library runs another process.
  module Quint
    COMMAND = ENV.fetch("QUINT", "npx --yes @informalsystems/quint@0.33.0").freeze

    # The spec's JSON IR.
    def self.compile(path)
      Dir.mktmpdir("quint") do |dir|
        # Into a file: through a pipe, quint exits before its 64 KB of JSON is out.
        out = File.join(dir, "ir.json")
        _, status = Open3.capture2e("#{COMMAND} compile --target json #{path} --out #{out}")
        raise "quint compile failed for #{path}" unless status.success? && File.exist?(out)

        JSON.parse(File.read(out))
      end
    end

    # Writes +traces+ traces of the spec's +step+ action and yields each file.
    def self.simulate(path, traces:, max_steps:, seed:, step: "step", backend: "rust")
      Dir.mktmpdir("quint") do |dir|
        command = "#{COMMAND} run #{path} --mbt --backend #{backend} --max-steps #{max_steps} --max-samples #{traces} " \
                  "--n-traces #{traces} --seed #{seed} --step #{step} --out-itf #{dir}/trace_{seq}.itf.json --verbosity 0"
        output, status = Open3.capture2e(command)
        raise "quint run failed:\n#{output}" unless status.success?

        Dir["#{dir}/trace_*.itf.json"].sort_by { _1[/(\d+)\.itf/, 1].to_i }.each { yield _1 }
      end
    end
  end
end
