# frozen_string_literal: true

source "https://rubygems.org"

# Headless data engine: the public web tier is site/ (Astro on Workers
# reading the D1 export). No server, router, view, or mailer gems.
gem "hanami", "~> 3.0.0"
gem "hanami-db", "~> 3.0.0"

gem "dry-operation", ">= 1.0.1"
gem "dry-types", "~> 1.7"
gem "rake"
gem "sqlite3"

group :development, :test do
  gem "dotenv"
  # Syntax highlighting SQL logs
  gem "rouge"
  gem "rubocop", require: false
end

group :cli, :development, :test do
  gem "hanami-rspec", "~> 3.0.0"
end

group :test do
  # Database
  gem "database_cleaner-sequel"
end
