class Api::V1::BookFilesController < Api::V1::BaseController
  def show
    book = find_book! or return

    file = params[:fmt].present? ? book.file_for(params[:fmt]) : book.kindle_file
    if file.nil? || !File.exist?(file.absolute_path)
      return render json: { error: "file not found" }, status: :not_found
    end

    send_file file.absolute_path,
      filename: file.filename,
      type: "application/octet-stream",
      disposition: "attachment"
  end
end
