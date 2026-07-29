# Reading activity: per-user web positions plus household Kindle
# ReadingState rows (physical devices only).
class ReadingController < ApplicationController
  def index
    @web_opened_count = Current.user.reader_positions.select(:book_id).distinct.count
    @web_finished_count = Current.user.reader_positions
      .where("percent > ?", Book::READING_FINISHED_THRESHOLD)
      .select(:book_id).distinct.count

    @web_positions = Current.user.reader_positions
      .includes(book: :book_files)
      .order(updated_at: :desc)
      .limit(100)

    kindle_states = ReadingState.joins(:device).merge(Device.physical)
      .includes(:device, book: :book_files)
      .order(content_mtime: :desc)
      .limit(600)
    @by_book = kindle_states.group_by(&:book).first(200)
    @kindle_book_count = @by_book.size
  end
end
