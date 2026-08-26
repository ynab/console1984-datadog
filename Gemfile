# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# CI sets RAILS_VERSION per matrix job to pin the whole Rails stack to one line.
# Unset resolves to the newest Rails the gemspec allows.
if (rails_version = ENV["RAILS_VERSION"])
  gem "rails", "~> #{rails_version}.0"
end

gem "rake"
gem "rspec", "~> 3.0"
gem "webmock", "~> 3.0"
gem "standard"
