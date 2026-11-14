require_relative "lib/quint_driver/version"

Gem::Specification.new do |spec|
  spec.name = "quint_driver"
  spec.version = QuintDriver::VERSION
  spec.authors = [ "meganemura" ]
  spec.summary = "Run a Ruby system the way a Quint spec says, and compare the two after every step."
  spec.homepage = "https://github.com/meganemura/quint_driver"
  spec.license = "MIT"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
  spec.required_ruby_version = ">= 3.3.0"
  spec.bindir = "exe"
  spec.executables = [ "quint_driver" ]
  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs","exe/quint_driver", "skills/quint_driver/SKILL.md", "examples/loans/*", "examples/shelf/*", "README.md", "README.ja.md", "LICENSE"]
end
