# frozen_string_literal: true

module D1Export
  # Leave room below D1's 100,000-byte statement limit, including SQL escaping.
  MAX_STATEMENT_BYTES = 90_000
  MAX_ROWS = 200

  def self.write_inserts(output, db, table)
    columns = db[table.to_sym].columns
    prefix = "INSERT INTO #{table} (#{columns.join(",")}) VALUES "
    values = []
    bytes = prefix.bytesize + 2
    db[table.to_sym].order(:id).each do |row|
      value = "(#{columns.map { |column| db.literal(row[column]) }.join(",")})"
      if prefix.bytesize + value.bytesize + 2 > MAX_STATEMENT_BYTES
        raise ArgumentError, "#{table} row #{row.fetch(:id)} exceeds the D1 statement byte budget"
      end

      if !values.empty? && (values.length >= MAX_ROWS || bytes + value.bytesize + 1 > MAX_STATEMENT_BYTES)
        output.puts "#{prefix}#{values.join(",")};"
        values = []
        bytes = prefix.bytesize + 2
      end
      bytes += value.bytesize + (values.empty? ? 0 : 1)
      values << value
    end
    output.puts "#{prefix}#{values.join(",")};" unless values.empty?
  end
end
