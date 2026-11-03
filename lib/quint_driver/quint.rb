require "json"
require "open3"
require "tmpdir"

module QuintDriver
  # The `quint` command line: the one place this library runs another process.
  module Quint
    # Read on every call, so a caller can set QUINT after requiring the gem.
    def self.command = ENV.fetch("QUINT", "npx --yes @informalsystems/quint@0.33.0")

    # The spec's JSON IR.
    def self.compile(path)
      Dir.mktmpdir("quint") do |dir|
        # Into a file: through a pipe, quint exits before its 64 KB of JSON is out.
        out = File.join(dir, "ir.json")
        output, status = capture("compile --target json #{path} --out #{out}")
        ir = File.exist?(out) ? JSON.parse(File.read(out)) : {}
        return ir if status.success? && ir.key?("modules")

        # With --out, quint writes its errors into the file and prints nothing;
        # a missing spec leaves no error at all, only the stage it stopped at.
        reasons = [ output.strip, *ir.fetch("errors", []).map { _1["explanation"] } ].reject(&:empty?)
        raise QuintFailed, "quint compile failed for #{path} at the #{ir.fetch('stage', 'start')} stage\n#{reasons.join("\n")}"
      end
    end

    # Writes +traces+ traces of the spec's +step+ action and yields each file.
    # +main+ names the module to run; without it, quint runs the module named
    # after the file.
    def self.simulate(path, traces:, max_steps:, seed:, main: nil, step: "step", backend: "rust")
      Dir.mktmpdir("quint") do |dir|
        arguments = "run #{path} --mbt --backend #{backend} --max-steps #{max_steps} --max-samples #{traces} " \
                    "--n-traces #{traces} --seed #{seed} --step #{step} --out-itf #{dir}/trace_{seq}.itf.json --verbosity 0"
        arguments += " --main #{main}" if main
        output, status = capture(arguments)
        raise QuintFailed, "quint run failed:\n#{output}" unless status.success?

        # The trace files go with dir, so a mismatch names the call that writes them again.
        call = "Quint.simulate(#{path.inspect}, " +
               { traces:, max_steps:, seed:, main:, step:, backend: }.compact.map { "#{_1}: #{_2.inspect}" }.join(", ") + ")"
        Dir["#{dir}/trace_*.itf.json"].sort_by { _1[/(\d+)\.itf/, 1].to_i }.each do |trace|
          yield trace
        rescue Mismatch => mismatch
          raise Mismatch, "#{mismatch.message}\n#{call} wrote this trace as #{File.basename(trace)}", mismatch.backtrace
        end
      end
    end

    def self.capture(arguments)
      Open3.capture2e("#{command} #{arguments}")
    rescue SystemCallError => error
      raise QuintFailed, "quint: cannot run `#{command}`; set QUINT to the quint command (#{error.message})"
    end
    private_class_method :capture
  end
end
