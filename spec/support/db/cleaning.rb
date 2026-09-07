# frozen_string_literal: true

require "database_cleaner/sequel"

# Clean the databases between tests tagged as `:db`
RSpec.configure do |config|
  all_databases = lambda {
    databases = Hanami.app.with_slices.each_with_object([]) do |slice, dbs|
      next unless slice.key?("db.rom")

      dbs.concat slice["db.rom"].gateways.values.map(&:connection)
    end
    # Validate every connection before cleaning any database. Test environment
    # URL rewriting alone cannot establish that an inherited path is disposable.
    databases.uniq.each { |db| SpecDatabaseSafety.validate!(db, root: SPEC_ROOT.parent.to_s) }
  }

  config.before :suite do
    all_databases.call.each do |db|
      DatabaseCleaner[:sequel, db: db].clean_with :truncation, except: ["schema_migrations"]
    end
  end

  config.prepend_before :each, :db do |example|
    strategy = example.metadata[:js] ? :truncation : :transaction

    all_databases.call.each do |db|
      DatabaseCleaner[:sequel, db: db].strategy = strategy
      DatabaseCleaner[:sequel, db: db].start
    end
  end

  config.after :each, :db do
    all_databases.call.each do |db|
      DatabaseCleaner[:sequel, db: db].clean
    end
  end
end
