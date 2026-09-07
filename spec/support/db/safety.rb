# frozen_string_literal: true

module SpecDatabaseSafety
  def self.validate!(db, root:)
    expected = File.join(root, "db", "rakkan_test.sqlite")
    actual = File.expand_path(db.opts[:database].to_s, root)
    safe = db.database_type == :sqlite && actual == expected &&
           !File.symlink?(actual) &&
           File.realpath(File.dirname(actual)) == File.join(File.realpath(root), "db")
    return if safe

    abort "Refusing test cleanup outside this checkout's db/rakkan_test.sqlite"
  end
end
