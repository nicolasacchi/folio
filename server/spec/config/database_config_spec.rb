# Guards the SQLite busy-timeout bump. Rails' sqlite3 adapter feeds the
# `timeout` config into the connection's busy_handler_timeout, so a writer
# waits this long for the lock before raising SQLite3::BusyException. The
# stock 5000ms was too low under batch indexing/embedding load (writers,
# incl. Solid Queue's process heartbeat, hit StatementTimeout); this asserts
# the raised value stays in place.
require "rails_helper"

RSpec.describe "SQLite database configuration" do
  it "waits at least 15s for the write lock (busy timeout)" do
    timeout = ActiveRecord::Base.connection_pool.db_config.configuration_hash[:timeout]
    expect(timeout).to be >= 15_000
  end
end
