# Guarantees every book has a file the stock Kindle reader can open by
# auto-converting the best source when none exists yet. Target is a joint
# MOBI6+KF8 file: the reader opens the KF8 half, while the firmware's
# Library UI only shows cover art for MOBI6 containers (KF8-only AZW3
# renders as a cover-less text tile — verified on 5.19.2).
class EnsureKindleFormatJob < ApplicationJob
  queue_as :default

  TARGET_FORMAT = "mobi".freeze
  CONVERSION_SOURCE_PREFERENCE = %w[epub fb2 docx html htmlz odt rtf lit cbz cbr djvu].freeze

  def perform(book_id)
    book = Book.find_by(id: book_id)
    return unless book
    return if book.kindle_file
    return if book.conversions.active.where(target_format: TARGET_FORMAT).exists?

    by_format = book.book_files.index_by(&:format)
    source = CONVERSION_SOURCE_PREFERENCE.filter_map { |format| by_format[format] }.first
    return unless source

    conversion = book.conversions.create!(book_file: source, target_format: TARGET_FORMAT)
    ConvertBookJob.perform_later(conversion.id)
  end
end
