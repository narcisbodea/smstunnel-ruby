# frozen_string_literal: true

require_relative "lib/smstunnel/version"

Gem::Specification.new do |spec|
  spec.name = "smstunnel"
  spec.version = SMSTunnel::VERSION
  spec.authors = ["Narcis Bodea"]
  spec.email = ["contact@narboweb.ro"]

  spec.summary = "Send texts from your own Ruby and Rails apps through your own Android phone, from your own number."
  spec.description = <<~TEXT.tr("\n", " ").strip
    The SMSTunnel client for Ruby: send texts and sign-in codes, look up their status, list your phones, read the
    texts your phone received. Standard library only, typed errors, idempotency keys for safe retries. For Rails: an
    install generator (initializer and credentials), an Active Job that never sends twice, and a Noticed delivery
    method.
  TEXT
  spec.homepage = "https://smstunnel.io"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => "https://smstunnel.io",
    "source_code_uri" => "https://github.com/narcisbodea/smstunnel-ruby",
    "documentation_uri" => "https://github.com/narcisbodea/smstunnel-ruby#readme",
    "changelog_uri" => "https://github.com/narcisbodea/smstunnel-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/narcisbodea/smstunnel-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*", "README.md", "CHANGELOG.md", "LICENSE"].select { |path| File.file?(path) }
  spec.require_paths = ["lib"]
end
