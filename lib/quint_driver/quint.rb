require "etc"
require "json"
require "open3"
require "shellwords"
require "tmpdir"

module QuintDriver
  # The `quint` command line: the one place this library runs another process.
  module Quint
    # Read on every call, so a caller can set QUINT after requiring the gem.
    def self.command = ENV.fetch("QUINT", "npx --yes @informalsystems/quint@0.33.0")

    # The spec's JSON IR, frozen. +main+ names the module quint checks;
    # without it, quint checks the module named after the file, and fails when
    # none is. A file compiles once per process and quint command, until its
    # text or the text of a file it imports changes: one compile costs a
    # second or two of node, and every Spec.new asks for one. Its other
    # modules reuse that compile: quint typechecks every module of the file
    # whichever is main, and --main only sets "main" and adds q::init and
    # q::step, which nothing here reads. They are `true` here: quint names
    # init and step there by default, and fails a module that lacks either,
    # though a caller can pass step: another action. Threads that ask for one
    # file at once wait for one compile; other files compile beside it.
    #
    # With +flat+, the IR holds only +main+, with each definition it imports
    # among its own declarations, as quint flattens a module before it runs
    # it. That is one compile per module, so only a module that imports asks
    # for it. quint drops each imported definition that neither q::init, nor
    # q::step, nor a declaration of +main+ reaches, so q::step there names
    # every one it can (imported_names): a module needs no action named step
    # to compile, and a definition only the caller reads stays.
    def self.compile(path, main: nil, flat: false)
      key = [ command, File.expand_path(path), (main if flat) ]
      wanted = main || File.basename(path, ".qnt")
      @locking.synchronize { @locks[key] ||= Mutex.new }.synchronize do
        sources = sources(path) if File.file?(path)
        cached_sources, ir = @compiled[key]
        if sources && sources == cached_sources && ir["modules"].any? { _1["name"] == wanted }
          return ir["main"] == wanted ? ir : ir.merge("main" => wanted).freeze
        end

        ir = compile_now(path, main, flat)
        @compiled[key] = [ sources, ir ] if sources
        ir
      end
    end
    @compiled = {}
    @locks = {}
    @locking = Mutex.new

    # The text of +path+ and of each file it imports, directly or through
    # another, by path. Quint resolves `from "name"` against the directory of
    # the file that writes it, and adds .qnt to the name, also to one that
    # ends in .qnt, so `from "start.qnt"` reads start.qnt.qnt. A name in
    # a comment reads as an import too, which costs only a file read.
    def self.sources(path, read = {})
      path = File.expand_path(path)
      return read if read.key?(path) || !File.file?(path)

      read[path] = File.read(path)
      read[path].scan(/\bfrom\s+"([^"]+)"/) do |(name)|
        sources(File.join(File.dirname(path), "#{name}.qnt"), read)
      end
      read
    end

    def self.compile_now(path, main, flat)
      Dir.mktmpdir("quint") do |dir|
        # Into a file: through a pipe, quint exits before its 64 KB of JSON is
        # out. With --out, quint writes the modules as the file has them; on
        # stdout it prints the main module flattened. The shell makes that file
        # before quint runs, so a flat compile that fails leaves it empty.
        out = File.join(dir, "ir.json")
        words = [ "compile", "--target", "json", path, *([ "--main", main ] if main), "--init", "true" ]
        output, status = if flat
                           capture(*words, "--step", "and(true, #{imported_names(compile(path, main:), main).join(', ')})", stdout: out)
                         else
                           capture(*words, "--step", "true", "--out", out)
                         end
        ir = File.size?(out) ? JSON.parse(File.read(out), freeze: true) : {}
        return ir if status.success? && ir.key?("modules")

        # With --out, quint writes its errors into the file and prints nothing;
        # a missing spec leaves no error at all, only the stage it stopped at,
        # and a missing module only the modules the file has. quint lists them
        # in an order an edit to one module can change; it numbers a module
        # after the text it parses, so its id gives the order of the file.
        modules = ir.fetch("modules", []).sort_by { _1["id"] }.map { _1["name"] }
        wanted = main || File.basename(path, ".qnt")
        missing = "no module is named #{wanted}; #{path} has #{modules.join(', ')}" if modules.any? && !modules.include?(wanted)
        reasons = [ output.strip, *ir.fetch("errors", []).map { _1["explanation"] }, missing.to_s ].reject(&:empty?)
        raise QuintFailed, "quint compile failed for #{path} at the #{ir.fetch('stage', 'start')} stage\n#{reasons.join("\n")}"
      end
    end

    # Each name +main+ imports, as an operand of `and` in an action, so a flat
    # compile whose --step names them keeps every definition +main+ imports,
    # not only the ones its own declarations reach. A value that is no
    # boolean is the comparison with itself. A definition with parameters
    # needs arguments, and a run or a temporal formula fits no action, so
    # those stay out: quint keeps one only where something else reaches it.
    # An instance names its definitions after the instance, so it adds none.
    def self.imported_names(ir, main)
      modules = ir.fetch("modules").to_h { [ _1["name"], _1 ] }
      shown = lambda do |name|
        modules.fetch(name).fetch("declarations").flat_map do |declaration|
          if declaration["kind"] == "def" then [ declaration ]
          elsif declaration["kind"] == "export" then shown.(declaration["protoName"]).map { renamed(_1, declaration) }
          else []
          end
        end
      end
      imported = modules.fetch(main).fetch("declarations").select { _1["kind"] == "import" }.flat_map do |import|
        shown.(import["protoName"]).select { [ nil, "*", _1["name"] ].include?(import["defName"]) }.map { renamed(_1, import) }
      end
      imported.uniq { _1["name"] }.filter_map do |declaration|
        next if declaration["expr"]["kind"] == "lambda" || %w[run temporal].include?(declaration["qualifier"])

        bool = declaration["qualifier"] == "action" || ir.dig("types", declaration["id"].to_s, "type", "kind") == "bool"
        bool ? declaration["name"] : "#{declaration['name']} == #{declaration['name']}"
      end
    end

    def self.renamed(declaration, import)
      import["qualifiedName"] ? declaration.merge("name" => "#{import['qualifiedName']}::#{declaration['name']}") : declaration
    end

    # Writes +traces+ traces of the spec's +step+ action and yields each file.
    # +main+ names the module to run; without it, quint runs the module named
    # after the file. +reach+ names a definition of the module that holds at
    # the state a test is after: each trace then ends at the first state where
    # it holds, and only the traces that get there are yielded.
    def self.simulate(path, traces:, max_steps:, seed:, main: nil, step: "step", backend: "rust", reach: nil)
      Dir.mktmpdir("quint") do |dir|
        refuse_unfound = runnable!(path, main:, step:, reach:)
        evaluator = self.evaluator if backend == "rust"
        input = evaluator_input(path, traces:, max_steps:, seed:, main:, step:, reach:) if evaluator
        if input
          write_traces(evaluator, input, dir)
        else
          arguments = [ "run", path, "--mbt", "--backend", backend, "--max-steps", max_steps, "--max-samples", traces,
                        "--n-traces", traces, "--seed", seed, "--step", step, "--out-itf", "#{dir}/trace_{seq}.itf.json", "--verbosity", 0 ]
          arguments += [ "--main", main ] if main
          # quint ends a trace where its invariant breaks, and exits 1 then.
          arguments += [ "--invariant", "not(#{reach})" ] if reach
          output, status = capture(*arguments)
          refuse_unfound.(output)
          raise QuintFailed, "quint run failed:\n#{output}" unless status.success? || reach && output.match?(/^error: invariant violated$/i)
        end

        # A trace that broke the invariant is one that reached +reach+.
        traces_written = Dir["#{dir}/trace_*.itf.json"].sort_by { _1[/(\d+)\.itf/, 1].to_i }
        traces_written.select! { JSON.parse(File.read(_1)).dig("#meta", "status") == "violation" } if reach
        if reach && traces_written.empty?
          raise QuintFailed, "quint: no trace of #{traces} reached #{reach} within #{max_steps} steps; raise max_steps or traces"
        end

        written_by = call("simulate", path, traces:, max_steps:, seed:, main:, step:, backend:, reach:)
        yield_traces(traces_written, seed:, written_by:) { yield _1 }
      end
    end

    # Raises ArgumentError when +step+ names no action without parameters, or
    # +reach+ no predicate. quint finds that out only while it runs, and its
    # two evaluators each say "Expected boolean" in words of their own. A
    # name the module does not declare may be one it imports, which this IR
    # does not hold, so the check it returns reads quint's output for a name
    # quint did not find either.
    def self.runnable!(path, main:, step:, reach:)
      ir = compile(path, main:)
      declarations = ir.fetch("modules").find { _1["name"] == ir["main"] }.fetch("declarations")
      kinds = declarations.select { _1["name"] }.to_h { [ _1["name"], kind_of(_1, ir.fetch("types")) ] }
      wanted = { "step" => [ step, "an action", "an action without parameters" ],
                 "reach" => [ reach, "a predicate", "a predicate, a boolean val or def without parameters" ] }
      refuse = lambda do |argument, what|
        name, kind, takes = wanted.fetch(argument)
        such_as = kinds.select { |of_name, of| of == kind && of_name != "init" && !of_name.start_with?("q::") }.keys.sort.join(", ")
        Agreement.refuse "quint: #{argument} names #{name}, #{what}; #{argument} takes #{takes}, such as #{such_as}"
      end
      wanted.each do |argument, (name, kind)|
        refuse.(argument, "#{kinds[name]} of #{ir['main']}") if kinds.key?(name) && kinds[name] != kind
      end
      lambda do |output|
        unfound = output[/\[QNT404\] Name '(.+)' not found/, 1]
        Agreement.refuse(without_init(ir["main"])) if unfound == "init"
        argument, = wanted.find { |_, (name)| name == unfound } if unfound
        refuse.(argument, "which #{ir['main']} neither declares nor imports") if argument
      end
    end

    # Quint's own --init could name another action, but a trace names its
    # first step after that action, the model and the machine step through
    # init, and a driver reads init: one name keeps the four alike.
    def self.without_init(main)
      "quint: #{main} neither declares nor imports an action named init; quint_driver starts every trace " \
        "and every model at init, so declare `action init = ...` with what starts #{main}"
    end

    # What a declaration is, as a step or a reach has to tell: a variant
    # quint declares as a val, or as a def when it carries a value. A val and
    # a def without parameters both read as a value: the keyword changes
    # nothing a step or a reach needs.
    def self.kind_of(declaration, types)
      expr = declaration["expr"] || {}
      lambda = expr["kind"] == "lambda"
      type = types.dig(declaration["id"].to_s, "type", "kind")
      case
      when declaration["kind"] == "var" then "a variable"
      when declaration["kind"] == "const" then "a constant"
      when declaration["kind"] != "def" then "a type"
      when (lambda ? expr["expr"] : expr)["opcode"] == "variant" then "a case of a sum type"
      when declaration["qualifier"] == "action" then lambda ? "an action with parameters" : "an action"
      when declaration["qualifier"] == "run" then "a run"
      when declaration["qualifier"] == "temporal" then "a temporal formula"
      when lambda then "a def with parameters"
      when type == "bool" then "a predicate"
      else "#{type.match?(/\A[aeiou]/) ? 'an' : 'a'} #{type} value"
      end
    end

    # Writes the trace of the run named +name+, such as
    # `run lendTest = init.then(...)`, and yields its file. +main+ names the
    # module that holds the run. quint test writes no mbt::actionTaken, so
    # replay it with Trace.replay's +action+: the spec has to record the
    # action each step took, as a Choreo spec does.
    def self.test(path, name, seed:, main: nil)
      Dir.mktmpdir("quint") do |dir|
        arguments = [ "test", path, "--match", "^#{name}$", "--seed", seed, "--max-samples", 1, "--out-itf", "#{dir}/test_{seq}.itf.json", "--verbosity", 1 ]
        arguments += [ "--main", main ] if main
        output, status = capture(*arguments)
        raise QuintFailed, "quint test failed:\n#{output}" unless status.success?

        written = Dir["#{dir}/test_*.itf.json"]
        if written.empty?
          ir = compile(path, main:)
          runs = ir["modules"].find { _1["name"] == ir["main"] }["declarations"].select { _1["qualifier"] == "run" }.map { _1["name"] }
          raise QuintFailed, "quint: no run is named #{name} in #{ir['main']}; it has #{runs.sort.join(', ')}"
        end
        yield_traces(written, seed:, written_by: call("test", path, name, seed:, main:)) { yield _1 }
      end
    end

    # The call that writes the same traces again, with the spec named as
    # raised in names a frame.
    def self.call(method, path, *names, **options)
      arguments = [ Agreement.relative(File.expand_path(path)), *names ].map(&:inspect)
      "Quint.#{method}(#{[ *arguments, *options.compact.map { "#{_1}: #{_2.inspect}" } ].join(', ')})"
    end

    # The trace files go with their directory, so a replay's failure names
    # its trace by +seed+ and +written_by+, the call that writes it again,
    # instead of by its path.
    def self.yield_traces(traces, seed:, written_by:)
      traces.each do |trace|
        @written[trace] = { seed:, written_by: }
        yield trace
      rescue Mismatch, StepRaised => failure
        name_trace(failure, trace)
        raise
      ensure
        @written.delete(trace)
      end
    end
    @written = {}

    # Names +trace+ on a +failure+ that names none and, while a simulate or
    # test block is yielding it, the seed and the call that write it again.
    # It keeps its class and cause, and leaves quint_driver's frames out of its
    # backtrace, as Agreement.outside says. Trace.replay calls it too, so
    # a block that rescues a replay's failure reads what the caller of
    # simulate reads.
    def self.name_trace(failure, trace)
      failure.send(:name_trace, trace, **@written[trace].to_h) unless failure.trace
      Agreement.lead_outside(failure)
    end

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
    # +step+ is no action of the module or +reach+ no definition of it, so
    # `quint run` reports it.
    def self.evaluator_input(path, traces:, max_steps:, seed:, main:, step:, reach:)
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
      invariant = if reach
                    table[(id += 1).to_s] = declarations.find { _1["kind"] == "def" && _1["name"] == reach } || return
                    { id: id + 1, kind: "app", opcode: "not", args: [ { id:, kind: "name", name: reach } ] }
                  else
                    { id: id + 1, kind: "bool", value: true }
                  end
      number = Integer(seed.to_s, exception: false) or raise QuintFailed, "quint: the seed #{seed.inspect} is not an integer"
      { parsed: { modules: ir["modules"], table:, main: ir["main"], init: named[0], step: named[1],
                  invariants: [ invariant ], witnesses: [] },
        source: path, nruns: traces, nsteps: max_steps, ntraces: traces, nthreads: [ traces, Etc.nprocessors ].min,
        seed: number, mbt: true, verbosity: 0 }
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
      # A violation is only possible when simulate asks to reach a definition.
      unless %w[ok violation].include?(result["status"])
        raise QuintFailed, "quint run failed:\n#{result.fetch('errors', []).map { "Error [#{_1['code']}]: #{_1['message']}" }.join("\n")}"
      end

      result["bestTraces"].each_with_index { |trace, index| File.write(File.join(dir, "trace_#{index}.itf.json"), JSON.generate(trace["states"])) }
    end

    # QUINT is a shell command, such as `npx --yes ...`, so the line runs
    # through a shell, and each word after it is quoted: an app's folder can
    # have a space in its name. +stdout+ is a file quint's output goes into.
    def self.capture(*words, stdout: nil)
      line = "#{command} #{Shellwords.join(words)}#{" > #{Shellwords.escape(stdout)}" if stdout}"
      output, status = Open3.capture2e(line)
      # Only npm prefixes its lines with "npm error", so these mean npx did
      # not get as far as running quint.
      fetch = output[/^npm (?:error|ERR!) code .*/] if !status.success? && !ENV.key?("QUINT")
      raise QuintFailed, "quint: QUINT is unset, and `#{command}` could not fetch quint (#{fetch}); install quint and set QUINT to its command" if fetch

      [ output, status ]
    rescue SystemCallError => error
      raise QuintFailed, "quint: cannot run `#{command}`; set QUINT to the quint command (#{error.message})"
    end
    private_class_method :call, :capture, :compile_now, :evaluator_input, :imported_names, :kind_of, :name_trace, :renamed, :runnable!, :sources, :without_init, :write_traces, :yield_traces
  end
end
