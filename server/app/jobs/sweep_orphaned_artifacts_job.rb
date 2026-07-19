# Recurring safety net for prepared-delivery / cover / thumbnail files that
# lost their referencing DB row (crash mid-write, a bug, a rename) and would
# otherwise accumulate under storage/ forever. See Library::StorageGc.
class SweepOrphanedArtifactsJob < ApplicationJob
  queue_as :default

  def perform
    Library::StorageGc.sweep!
  end
end
