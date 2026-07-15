class BooksController < ApplicationController
  before_action :set_book, only: [ :show, :edit, :update, :destroy, :cover, :download, :reindex ]

  PER_PAGE = 48
  SORTS = %w[recent title author].freeze
  # "title" searches titles/authors/series (the default); "full" also digs
  # through descriptions and the Calibre-extracted text; "semantic" uses
  # the embedding index.
  SEARCH_MODES = %w[title full semantic].freeze

  def index
    @query = params[:q].to_s.strip
    if @query.present?
      @semantic_available = Library::Embeddings.available? && Library::Embeddings.count.positive?
      @mode = SEARCH_MODES.include?(params[:mode]) ? params[:mode] : "title"
      @mode = "title" if @mode == "semantic" && !@semantic_available
      if @mode == "semantic"
        hits = Library::Embeddings.nearest(text: @query, limit: 24)
        books = Book.includes(:book_files).where(id: hits.map(&:first)).index_by(&:id)
        @semantic_books = hits.filter_map { |id, _| books[id] }
      else
        @hits = Book.search(@query, scope: @mode == "full" ? :all : :metadata)
      end
    else
      @author = params[:author].presence
      @series = params[:series].presence
      @format = params[:format].presence
      @year = params[:year].presence&.to_i
      @language = params[:language].presence
      @added = parse_date(params[:added])
      @sort = SORTS.include?(params[:sort]) ? params[:sort] : "recent"

      scope = Book.all
      scope = scope.where(author: @author) if @author
      scope = scope.where(series: @series) if @series
      scope = scope.where(id: BookFile.where(format: @format).select(:book_id)) if @format
      scope = scope.where(published_year: @year) if @year
      scope = scope.where(language: @language) if @language
      scope = scope.where(created_at: @added.all_day) if @added
      scope = case @sort
      when "title" then scope.order(Arel.sql("lower(title)"), :id)
      when "author" then scope.order(Arel.sql("lower(coalesce(author, ''))"), Arel.sql("lower(title)"), :id)
      else
                # Inside a series, reading order beats recency.
                @series ? scope.order(:series_index, :id) : scope.order(created_at: :desc, id: :desc)
      end

      @total = scope.count
      @page = [ params[:page].to_i, 1 ].max
      @last_page = [ (@total / PER_PAGE.to_f).ceil, 1 ].max
      @page = @last_page if @page > @last_page
      @books = scope.includes(:book_files).offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

      @stats = Rails.cache.fetch("library_stats", expires_in: 10.minutes) do
        { books: Book.count, files: BookFile.count, bytes: BookFile.sum(:size) }
      end

      # The "keep reading" shelf only heads the unfiltered front page.
      if @page == 1 && !@author && !@series && !@format && !@year && !@language && !@added
        @currently_reading = Book.currently_reading(limit: 10)
      end
    end
  end

  def show
    @conversions = @book.conversions.order(created_at: :desc).limit(10)
    @similar = similar_books
    @devices = Device.physical.order(:name)
    @deliveries = @book.deliveries.index_by(&:device_id)
    @annotations = @book.annotations.with_content.includes(:device).recent.limit(100)
  end

  def edit
  end

  def update
    if @book.update(book_params)
      # Metadata lives in the search index and semantic vectors too.
      IndexBookJob.perform_later(@book.id)
      EmbedBookJob.perform_later(@book.id) if Library::Embeddings.available?
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

  # Full-text extraction is deliberately not part of folder scans (Calibre-
  # converting thousands of books up front would take days); this queues it
  # for one book on demand.
  def reindex
    IndexBookJob.perform_later(@book.id)
    redirect_to @book, notice: "Full-text indexing queued."
  end

  private

  def similar_books
    return [] unless Library::Embeddings.available? && Library::Embeddings.count.positive?

    hits = Library::Embeddings.nearest(book: @book, limit: 6)
    books = Book.where(id: hits.map(&:first)).index_by(&:id)
    hits.filter_map { |id, _| books[id] }
  rescue StandardError
    []
  end

  def set_book
    @book = Book.find(params[:id])
  end

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue Date::Error
    nil
  end

  def book_params
    params.expect(book: [ :title, :author, :series, :series_index, :language, :description, :published_year ])
  end
end
