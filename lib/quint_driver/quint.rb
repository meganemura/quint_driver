require "etc"
require "json"
require "open3"
require "tmpdir"

module QuintDriver
  # The `quint` command line: the one place this library runs another process.
  module Quint
    # Read on every call, so a caller can set QUINT after requiring the gem.
    def self.command = ENV.fetch("QUINT", "npx --yes @informalsystems/quint@0.33.0")

    # The spec's JSON IR, frozen. +main+ names the module quint checks;
    # without it, quint checks the module named after the file, and fails when
    # none is. A file compiles once per process and quint command, until its
    # text changes: one compile costs a second of node, and every Spec.new
    # asks for one.
    def self.compile(path, main: nil)
      key = [ command, File.expand_path(path), main ]
      source = File.read(path) if File.file?(path)
      cached_source, ir = @compiled[key]
      return ir if source && source == cached_source

      ir = compile_now(path, main)
      @compiled[key] = [ source, ir ] if source
      ir
    end
    @compiled = {}

    def self.compile_now(path, main)
      Dir.mktmpdir("quint") do |dir|
        # Into a file: through a pipe, quint exits before its 64 KB of JSON is out.
        out = File.join(dir, "ir.json")
        output, status = capture("compile --target json #{path} --out #{out}#{" --main #{main}" if main}")
        ir = File.exist?(out) ? JSON.parse(File.read(out), freeze: true) : {}
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
        evaluator = self.evaluator if backend == "rust"
        input = evaluator_input(path, traces:, max_steps:, seed:, main:, step:) if evaluator
        if input
          write_traces(evaluator, input, dir)
        else
          arguments = "run #{path} --mbt --backend #{backend} --max-steps #{max_steps} --max-samples #{traces} " \
                      "--n-traces #{traces} --seed #{seed} --step #{step} --out-itf #{dir}/trace_{seq}.itf.json --verbosity 0"
          arguments += " --main #{main}" if main
          output, status = capture(arguments)
          raise QuintFailed, "quint run failed:\n#{output}" unless status.success?
        end

        # The trace files go with dir, so Trace.replay names a trace by the
        # call that writes it again instead of by its path.
        call = "Quint.simulate(#{path.inspect}, " +
               { traces:, max_steps:, seed:, main:, step:, backend: }.compact.map { "#{_1}: #{_2.inspect}" }.join(", ") + ")"
        Dir["#{dir}/trace_*.itf.json"].sort_by { _1[/(\d+)\.itf/, 1].to_i }.each do |trace|
          @simulated[trace] = { seed:, simulate: call }
          yield trace
        ensure
          @simulated.delete(trace)
        end
      end
    end
    @simulated = {}

    # The seed and the call of the simulate block that is yielding +trace+,
    # or nil.
    def self.simulated(trace) = @simulated[trace]

    # The Rust evaluator quint 0.33.0 runs under `quint run --backend rust`.
    # Its stdin format is not a documented interface, so the gem reads only
    # this version's.
    EVALUATOR_VERSION = "v0.7.0"

    # The Rust evaluator simulate runs, without node: QUINT_EVALUATOR names
    # it, and an empty QUINT_EVALUATOR means `quint run`. Unset, it is the copy
    # quint downloaded into QUINT_HOME (~/.quint by default), or `quint run`
    # when there is none.
    def self.evaluator
      return ENV["QUINT_EVALUATOR"].then { _1.empty? ? nil : _1 } if ENV.key?("QUINT_EVALUATOR")

      home = ENV.fetch("QUINT_HOME") { File.join(Dir.home, ".quint") }
      found = File.join(home, "rust-evaluator-#{EVALUATOR_VERSION}", Gem.win_platform? ? "quint_evaluator.exe" : "quint_evaluator")
      found if File.executable?(found)
    end

    # What `quint run --mbt` sends the evaluator for this call, or nil when
    # +step+ is no action of the module, so `quint run` reports it.
    def self.evaluator_input(path, traces:, max_steps:, seed:, main:, step:)
      ir = compile(path, main:)
      declarations = ir.fetch("modules").find { _1["name"] == ir["main"] }&.fetch("declarations") || []
      table = ir.fetch("table").dup
      id = table.keys.map(&:to_i).max.to_i
      # quint parses --init and --step into name nodes with fresh ids, and
      # the table resolves each id to the action.
      named = %w[init].push(step).map do |action|
        definition = declarations.find { _1["kind"] == "def" && _1["qualifier"] == "action" && _1["name"] == action } or return
        table[(id += 1).to_s] = definition
        { "id" => id, "kind" => "name", "name" => action }
      end
      seed = Integer(seed.to_s, exception: false) or raise QuintFailed, "quint: the seed #{seed.inspect} is not an integer"
      { parsed: { modules: ir["modules"], table:, main: ir["main"], init: named[0], step: named[1],
                  invariants: [ { id: id + 1, kind: "bool", value: true } ], witnesses: [] },
        source: path, nruns: traces, nsteps: max_steps, ntraces: traces, nthreads: [ traces, Etc.nprocessors ].min,
        seed:, mbt: true, verbosity: 0 }
    end

    # Writes each trace the evaluator returns as quint would: trace_0.itf.json
    # onwards, in the order it returns them.
    def self.write_traces(evaluator, input, dir)
      output, errors, status = begin
        Open3.capture3(evaluator, "simulate-from-stdin", stdin_data: JSON.generate(input))
      rescue SystemCallError => error
        raise QuintFailed, "quint: cannot run the Rust evaluator #{evaluator}; set QUINT_EVALUATOR to it, or to an empty string to simulate through `quint run` (#{error.message})"
      end
      raise QuintFailed, "quint: the Rust evaluator #{evaluator} failed:\n#{errors}" unless status.success?

      result = begin
        JSON.parse(output.lines.reverse.find { _1.start_with?("{") }.to_s)
      rescue JSON::ParserError
      end
      unless result.is_a?(Hash) && result["bestTraces"].is_a?(Array) && result["bestTraces"].all? { _1["states"].is_a?(Hash) }
        raise QuintFailed, "quint: the Rust evaluator #{evaluator} answered in a format quint_driver does not read; " \
                           "it reads the #{EVALUATOR_VERSION} evaluator quint 0.33.0 runs. Set QUINT_EVALUATOR to that " \
                           "evaluator, or to an empty string to simulate through `quint run`"
      end
      raise QuintFailed, "quint run failed:\n#{result.fetch('errors', []).map { "Error [#{_1['code']}]: #{_1['message']}" }.join("\n")}" unless result["status"] == "ok"

      result["bestTraces"].each_with_index { |trace, index| File.write(File.join(dir, "trace_#{index}.itf.json"), JSON.generate(trace["states"])) }
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
    private_class_method :capture, :compile_now, :evaluator_input, :write_traces
  end
end
