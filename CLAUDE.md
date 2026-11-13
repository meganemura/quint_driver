# AGENTS.md

Context for agents that work in this repository.

## What this is

quint_driver tests a Ruby system against a Quint spec.
A driver runs the spec's actions on the system and reports the spec's variables as plain values.
Two ways share that driver: `Trace.replay` runs traces `quint run --mbt` wrote, and `QuintDriver.machine` builds a `Hegel::StateMachine` so Hegel picks the steps and shrinks a failure.
The spec is evaluated in the Ruby process (`Model`), and the model is held to Quint by replaying Quint's own traces through it.

## Layout

- `lib/quint_driver/quint.rb` is the one place that runs the `quint` command.
- `trace.rb` reads ITF traces and replays them on a driver. `spec.rb` reads one module of the JSON IR and the rules of a step action. `model.rb` evaluates the IR. `hegel.rb` is the Hegel adapter, loaded only by `require "quint_driver/hegel"`.
- `skills/quint_driver/` is the agent skill that ships with the repository.
- `examples/loans/` is a small spec, a system, a broken system, and their driver. The tests use it.
- `examples/shelf/` is a spec that splits a reservation into its read and its write, a system that loses an update, and a driver that holds each reservation with `QuintDriver::Hold`.
- `test/` is Minitest, `spec/` is RSpec. Both suites must pass: the library must work under either framework. The Hegel tests are in `test/hegel/` and `spec/hegel/`; the rest is the core.
- `test/fixture/depot/` is a small Rails app with a Gemfile and a lock of its own, and the gem does not ship it. It has four bugs planted, and nothing under its `app/` may say so: the list is in `test/depot_test.rb` and at the top of `spec/quint/depot_spec.rb`. Its `spec/quint/` hunts for them the way an agent would in an app of its own, and `fixed.patch` takes them out of the app and out of the actions of `depot.qnt`.

## Visibility

This repository is intended for public release.
Write all committed text in English: code, comments, docs, commit messages.
`README.ja.md` is the one Japanese file. It follows `README.md` in the same commit, in natural Japanese, one sentence per line, with no em dash.
Do not reference private tools, private repositories, or internal working documents in committed content.

## Rules

- The gem has no runtime dependency. `hegeltest` is in the Gemfile's `hegel` group, pinned exactly, and only `lib/quint_driver/hegel.rb` requires it. Add a dependency only with the owner's approval, pinned exactly, at least 7 days past its release.
- `lib/` refers to no test framework. A disagreement raises `QuintDriver::Mismatch`.
- An IR operator the model does not know, or a step shape no driver can run, raises `QuintDriver::Unsupported`. Never guess an operator's meaning. A failed `quint` command raises `QuintDriver::QuintFailed`.
- Comments say why: the constraint, or the alternative that was refused. Each module starts with its responsibility.
- Tests prove behavior by running Quint and the example system. A test never greps source.
- A release or a change of the repository's visibility is the owner's to run. A commit that changes `lib/quint_driver/version.rb` and lands on `main` starts `.github/workflows/release.yml`, and [docs/releasing.md](docs/releasing.md) has the steps. Every change that a gem user can notice adds a line under `## [Unreleased]` in `CHANGELOG.md`.

## Commands

- `bundle exec bin/test` runs the Minitest suite.
- `bundle exec rspec` runs the RSpec suite.
- Both run `quint`. Set `QUINT` to a local command; without it the library runs `npx --yes @informalsystems/quint@0.33.0`.
- The core (everything but `hegel.rb`) keeps Ruby 3.3 as its floor: `BUNDLE_WITHOUT=hegel bundle exec bin/test test/*_test.rb` on Ruby 3.3. The Hegel adapter needs Ruby 3.4, as hegeltest does.
- `test/depot_test.rb` runs the depot's specs on a copy of the app, as committed and with `fixed.patch` applied. It needs the depot's gems, so it skips until `bundle install` has run in `test/fixture/depot`. `QUINT_DRIVER_DEPOT=required` turns that skip into a failure, as CI's `depot` job does.
- `skills/quint_driver/SKILL.md` is the usage skill for an agent. A change to the API, a spec shape rule, or a failure message changes it in the same commit. Run every command and code block in it before you change it, and paste failure output from a real run.
