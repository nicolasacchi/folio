class ConversionsController < ApplicationController
  def create
    book = Book.find(params[:book_id])
    target = params[:target_format].to_s

    unless Conversion::TARGET_FORMATS.include?(target)
      return redirect_to book, alert: "Unsupported target format."
    end
    if book.file_for(target)
      return redirect_to book, alert: "Book already has a #{target.upcase} file."
    end
    if book.conversions.active.where(target_format: target).exists?
      return redirect_to book, notice: "That conversion is already queued."
    end

    by_format = book.book_files.index_by(&:format)
    source = Conversion::SOURCE_PREFERENCE.filter_map { |format| format == target ? nil : by_format[format] }.first
    return redirect_to book, alert: "No convertible source file." unless source

    conversion = book.conversions.create!(book_file: source, target_format: target)
    ConvertBookJob.perform_later(conversion.id)
    redirect_to book, notice: "Converting #{source.format.upcase} → #{target.upcase}…"
  end
end
