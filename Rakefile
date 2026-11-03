# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rubocop/rake_task"

namespace :test do
  Rake::TestTask.new(:unit) do |t|
    t.description = "Client tests, HTTP mocked (no Rails needed)"
    t.libs << "test"
    t.pattern = "test/unit/**/*_test.rb"
    t.warning = true
  end

  Rake::TestTask.new(:rails) do |t|
    t.description = "Generator, Active Job and Noticed tests, HTTP mocked (needs the :rails group)"
    t.libs << "test"
    t.pattern = "test/rails/**/*_test.rb"
    t.warning = false
  end

  Rake::TestTask.new(:e2e) do |t|
    t.description = "End-to-end tests against a local SMSTunnel test server (set SMSTUNNEL_E2E_KEY_FILE)"
    t.libs << "test"
    t.pattern = "test/e2e/**/*_test.rb"
    t.warning = true
  end
end

rails_bundled = begin
  Gem::Specification.find_by_name("noticed")
  true
rescue Gem::MissingSpecError
  false
end

desc "Unit tests, plus the Rails tests when the :rails group is installed"
task test: rails_bundled ? %w[test:unit test:rails] : %w[test:unit]

RuboCop::RakeTask.new

task default: %i[test rubocop]
