class ConversionsController < ApplicationController
  def create
    book = Book.find(params[:book_id])
    kind = Conversion::KINDS.include?(params[:kind].to_s) ? params[:kind].to_s : "calibre"

    return create_ocr(book) if kind == "ocr"

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

  private

  # kind=ocr: pdf -> pdf text-layer companion (see Library::Ocr,
  # OcrBookJob), not a new format, so this skips the target_format /
  # file_for(target) checks above entirely — those assume the target is a
  # format the book doesn't have yet, which is the opposite of what OCR
  # needs (Book#ocr_candidate_file requires an existing pdf book_file).
  def create_ocr(book)
    source = book.ocr_candidate_file
    return redirect_to book, alert: "No scanned PDF to OCR." unless source
    if book.conversions.active.where(kind: "ocr").exists?
      return redirect_to book, notice: "That conversion is already queued."
    end

    conversion = book.conversions.create!(book_file: source, target_format: "pdf", kind: "ocr")
    OcrBookJob.perform_later(conversion.id)
    redirect_to book, notice: "Running OCR on the scanned PDF…"
  end
end
