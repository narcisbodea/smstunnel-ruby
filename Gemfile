# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest", "~> 5.25"
gem "rake", "~> 13.2"
gem "rubocop", "~> 1.81", require: false
gem "rubocop-minitest", "~> 0.38", require: false
gem "rubocop-rake", "~> 0.7", require: false
gem "webmock", "~> 3.25"

# Only for the Rails tests (generator, Active Job, Noticed). Skip them with BUNDLE_WITHOUT=rails: the gem itself
# needs nothing but the standard library.
group :rails do
  rails_version = ENV.fetch("RAILS_VERSION", "8.1")
  gem "noticed", ENV.fetch("NOTICED_VERSION", ">= 2.9")
  gem "rails", "~> #{rails_version}.0"
  gem "sqlite3", ">= 1.4"
  # Active Support 8.0.5 still passes quirks_mode to JSON.generate, which json 3 refuses.
  gem "json", "< 3" if rails_version == "8.0"
end
