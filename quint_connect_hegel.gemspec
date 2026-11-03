require_relative "lib/quint_connect_hegel/version"

Gem::Specification.new do |spec|
  spec.name = "quint_connect_hegel"
  spec.version = QuintConnectHegel::VERSION
  spec.authors = [ "meganemura" ]
  spec.summary = "Test a Ruby system against a Quint spec, with Hegel choosing and shrinking the steps."
  spec.homepage = "https://github.com/meganemura/quint-connect-hegel-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.add_dependency "hegeltest", "= 0.4.1"
end
