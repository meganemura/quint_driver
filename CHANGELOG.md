# Changelog

## [Unreleased]

First release. quint_driver holds Ruby code to a [Quint](https://github.com/quint-co/quint) spec: a driver runs each action of the spec on your code and reads your code back as the spec's variables, and quint_driver compares the two after every step.

- `QuintDriver::Quint.simulate` runs `quint run --mbt` and yields each trace, and `QuintDriver::Trace.replay` runs a trace on a driver step by step. `reach:` ends each trace at the first state where a definition holds. `QuintDriver::Quint.test` replays the trace of a named `run`.
- `QuintDriver.machine` builds a `Hegel::StateMachine` from the spec, so [hegeltest](https://github.com/meganemura/hegel-ruby) picks each step from the actions the spec allows now and shrinks a failure to a short sequence of commands. `invariants:` names the spec's `val`s that must hold after every move. It loads with `require "quint_driver/hegel"`.
- `QuintDriver::Mismatch` names each variable that differs and the steps from `init`, so the failure can be run again by hand. An error a step raises, in the driver or in the system, comes out as `QuintDriver::StepRaised`, and a failed `quint` command as `QuintDriver::QuintFailed`.
- The spec is read from Quint's JSON IR and evaluated in the Ruby process (`Spec#model`), so a Hegel step starts no other process. The model can be held to Quint's own traces with `Trace.replay`. An operator it does not know raises `QuintDriver::Unsupported`. A pick can be any value the spec draws, `false` and `None` included, and `Bool` is the set of both booleans. A pick from `Int` or `Nat`, which no move can list, raises `QuintDriver::Unsupported`.
- `Quint.simulate` runs Quint's Rust evaluator directly when quint has downloaded it, without node.
- An agent skill in `skills/quint_driver/`. The gem ships it with the `examples/loans` spec and `README.ja.md`, so `bundle info --path quint_driver` finds them without GitHub access.
- Ruby 3.3 or newer, with no runtime dependency. The Hegel adapter needs hegeltest 0.4.1 and Ruby 3.4 or newer, in your own Gemfile.
