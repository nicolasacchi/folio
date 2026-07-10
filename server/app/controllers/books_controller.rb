class BooksController < ApplicationController
  before_action :set_book, only: [ :show, :edit, :update, :destroy, :cover, :download ]

  def index
    @query = params[:q].to_s.strip
    if @query.present?
      @hits = Book.search(@query)
    else
      @books = Book.includes(:book_files).order(created_at: :desc)
    end
  end

  def show
    @conversions = @book.conversions.order(created_at: :desc).limit(10)
  end

  def edit
  end

  def update
    if @book.update(book_params)
      # Metadata lives in the search index too; keep it in sync.
      IndexBookJob.perform_later(@book.id)
      redirect_to @book, notice: "Book updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @book.destroy!
    redirect_to root_path, notice: "Book deleted.", status: :see_other
  end

  def cover
    unless @book.cover?
      return head :not_found
    end
    fresh_when last_modified: File.mtime(@book.cover_path)
    return if request.fresh?(response)

    send_file @book.cover_path, type: "image/jpeg", disposition: "inline"
  end

  def download
    file = params[:fmt].present? ? @book.file_for(params[:fmt]) : @book.kindle_file
    if file.nil? || !File.exist?(file.absolute_path)
      return redirect_to @book, alert: "File not available."
    end

    send_file file.absolute_path, filename: file.filename, type: "application/octet-stream"
  end

  private

  def set_book
    @book = Book.find(params[:id])
  end

  def book_params
    params.expect(book: [ :title, :author, :series, :series_index, :language, :description, :published_year ])
  end
end
