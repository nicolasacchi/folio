class Api::V1::BookFilesController < Api::V1::BaseController
  def show
    book = find_delivered_book! or return

    file = params[:fmt].present? ? book.file_for(params[:fmt]) : book.kindle_file
    delivery = current_device.deliveries.find_by(book: book)
    # This device's own variant choice (see Delivery#variant) — same
    # variant both the existence check and send_file resolve, so they can
    # never disagree.
    variant = delivery&.variant || "auto"
    path = file&.delivery_path(variant: variant)
    if file.nil? || !File.exist?(path)
      return render json: { error: "file not found" }, status: :not_found
    end

    delivery&.update!(delivered_at: Time.current)

    send_file path,
      filename: file.delivery_filename(variant: variant),
      type: "application/octet-stream",
      disposition: "attachment"
  end
end
