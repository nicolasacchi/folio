# Extracts best-effort progress signals from a freshly synced .sdr bundle
# (see Library::SidecarProgress). Cheap (tar.gz inspection, no Calibre),
# so it lives on the default queue.
class ParseSidecarJob < ApplicationJob
  queue_as :default

  def perform(reading_state_id)
    state = ReadingState.find_by(id: reading_state_id)
    return unless state && File.exist?(state.absolute_path)

    result = Library::SidecarProgress.parse(state.absolute_path)
    state.update!(
      sidecar_files: result.files,
      last_position: result.last_position,
      annotation_count: result.annotation_count,
      progress_source: result.source,
      progress_percent: estimate_percent(state.book, result.last_position),
      parsed_at: Time.current
    )
  end

  private

  # Rough by construction: MBP positions are offsets into the book text,
  # while the only denominator we always have is the delivered file's
  # size (which includes markup/images). Shown with a "~" in the UI.
  def estimate_percent(book, position)
    return nil unless position&.positive?

    file = book.kindle_file
    return nil unless file && file.size.to_i.positive?

    ((position.to_f / file.size) * 100).clamp(0.0, 100.0).round(1)
  end
end
