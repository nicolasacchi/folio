class Api::V1::BookFilesController < Api::V1::BaseController
  def show
    book = find_delivered_book! or return

    file = params[:fmt].present? ? book.file_for(params[:fmt]) : book.kindle_file
    delivery = current_device.deliveries.find_by(book: book)
    # This device's own OCR/original choice (see Delivery#raw) — same path
    # both the existence check and send_file resolve, so they can never
    # disagree.
    path = file&.delivery_path(raw: delivery&.raw || false)
    if file.nil? || !File.exist?(path)
      return render json: { error: "file not found" }, status: :not_found
    end

    delivery&.update!(delivered_at: Time.current)

    send_file path,
      filename: file.delivery_filename,
      type: "application/octet-stream",
      disposition: "attachment"
  end
end
