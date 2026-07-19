# Recurring safety net for conversions whose worker died mid-run (crashed
# process, killed container, ...) and were left stuck in "running" forever.
# See Conversion.sweep_stuck! / Conversion::STUCK_AFTER.
class SweepStuckConversionsJob < ApplicationJob
  queue_as :default

  def perform
    Conversion.sweep_stuck!
  end
end
