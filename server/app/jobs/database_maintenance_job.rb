# Recurring SQLite housekeeping — see DatabaseMaintenance for the actual
# PRAGMA work (WAL checkpoint + a quick_check canary on the primary).
# Runs on the default queue: a handful of PRAGMA calls, not CPU/Calibre
# work, so it doesn't need the conversion queue's single-thread discipline.
class DatabaseMaintenanceJob < ApplicationJob
  queue_as :default

  def perform
    DatabaseMaintenance.run!
  end
end
