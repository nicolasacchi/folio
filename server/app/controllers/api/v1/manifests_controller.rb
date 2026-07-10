class Api::V1::ManifestsController < Api::V1::BaseController
  # The device manifest lists one deliverable (Kindle-ready) file per book,
  # plus enough reading-state info for the daemon to sync sidecars without
  # extra round-trips.
  def show
    books = Book.includes(:book_files, :reading_states).order(:title)

    items = books.filter_map do |book|
      file = book.kindle_file
      next unless file

      {
        id: book.public_id,
        title: book.title,
        author: book.author,
        series: book.series,
        format: file.format,
        filename: file.filename,
        size: file.size,
        sha256: file.sha256,
        url: api_v1_book_file_path(public_id: book.public_id, fmt: file.format),
        reading_state: reading_state_summary(book)
      }
    end

    render json: { version: 2, generated_at: Time.current.to_i, items: items }
  end

  private

  def reading_state_summary(book)
    state = book.reading_states.max_by(&:content_mtime)
    return nil unless state

    {
      mtime: state.content_mtime.to_i,
      sha256: state.sha256,
      size: state.size,
      device_id: state.device_id,
      url: api_v1_book_reading_state_path(public_id: book.public_id)
    }
  end
end
