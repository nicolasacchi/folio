# Guarantees every book has a file the stock Kindle reader can open by
# auto-converting the best source to AZW3 when none exists yet.
class EnsureKindleFormatJob < ApplicationJob
  queue_as :default

  CONVERSION_SOURCE_PREFERENCE = %w[epub fb2 docx html htmlz odt rtf lit cbz cbr djvu].freeze

  def perform(book_id)
    book = Book.find_by(id: book_id)
    return unless book
    return if book.kindle_file
    return if book.conversions.active.where(target_format: "azw3").exists?

    by_format = book.book_files.index_by(&:format)
    source = CONVERSION_SOURCE_PREFERENCE.filter_map { |format| by_format[format] }.first
    return unless source

    conversion = book.conversions.create!(book_file: source, target_format: "azw3")
    ConvertBookJob.perform_later(conversion.id)
  end
end
