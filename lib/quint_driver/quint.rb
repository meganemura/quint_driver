require "json"
require "open3"
require "tmpdir"

module QuintDriver
  # The `quint` command line: the one place this library runs another process.
  module Quint
    # Read on every call, so a caller can set QUINT after requiring the gem.
    def self.command = ENV.fetch("QUINT", "npx --yes @informalsystems/quint@0.33.0")

    # The spec's JSON IR. +main+ names the module quint checks; without it,
    # quint checks the module named after the file, and fails when none is.
    def self.compile(path, main: nil)
      Dir.mktmpdir("quint") do |dir|
        # Into a file: through a pipe, quint exits before its 64 KB of JSON is out.
        out = File.join(dir, "ir.json")
        output, status = capture("compile --target json #{path} --out #{out}#{" --main #{main}" if main}")
        ir = File.exist?(out) ? JSON.parse(File.read(out)) : {}
        return ir if status.success? && ir.key?("modules")

        # With --out, quint writes its errors into the file and prints nothing;
        # a missing spec leaves no error at all, only the stage it stopped at,
        # and a missing module only the modules the file has.
        modules = ir.fetch("modules", []).map { _1["name"] }
        wanted = main || File.basename(path, ".qnt")
        missing = "no module is named #{wanted}; #{path} has #{modules.join(', ')}" if modules.any? && !modules.include?(wanted)
        reasons = [ output.strip, *ir.fetch("errors", []).map { _1["explanation"] }, missing.to_s ].reject(&:empty?)
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

        # The trace files go with dir, so a mismatch names the trace by its
        # seed instead of its path, and the call that writes it again.
        call = "Quint.simulate(#{path.inspect}, " +
               { traces:, max_steps:, seed:, main:, step:, backend: }.compact.map { "#{_1}: #{_2.inspect}" }.join(", ") + ")"
        Dir["#{dir}/trace_*.itf.json"].sort_by { _1[/(\d+)\.itf/, 1].to_i }.each do |trace|
          yield trace
        rescue Mismatch => mismatch
          named = mismatch.message.sub(trace, "#{File.basename(trace)} (seed #{seed.inspect})")
          raise Mismatch, "#{named}\n#{call} wrote this trace as #{File.basename(trace)}", mismatch.backtrace, cause: nil
        end
      end
    end

    def self.capture(arguments)
      output, status = Open3.capture2e("#{command} #{arguments}")
      # Only npm prefixes its lines with "npm error", so these mean npx did
      # not get as far as running quint.
      fetch = output[/^npm (?:error|ERR!) code .*/] if !status.success? && !ENV.key?("QUINT")
      raise QuintFailed, "quint: QUINT is unset, and `#{command}` could not fetch quint (#{fetch}); install quint and set QUINT to its command" if fetch

      [ output, status ]
    rescue SystemCallError => error
      raise QuintFailed, "quint: cannot run `#{command}`; set QUINT to the quint command (#{error.message})"
    end
    private_class_method :capture
  end
end
