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

  # Sidecar positions are offsets into the uncompressed text, so prefer
  # the MOBI header's text_length as denominator; the file size fallback
  # (markup/images included) stays rough — hence the "~" in the UI.
  def estimate_percent(book, position)
    return nil unless position&.positive?

    file = book.kindle_file
    return nil unless file

    denominator = Library::Mobi.text_length(file.absolute_path) || file.size.to_i
    return nil unless denominator.positive?

    ((position.to_f / denominator) * 100).clamp(0.0, 100.0).round(1)
  end
end
