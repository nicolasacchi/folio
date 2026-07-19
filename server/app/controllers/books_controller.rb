class BooksController < ApplicationController
  before_action :set_book, only: [ :show, :edit, :update, :destroy, :cover, :download, :reindex ]

  PER_PAGE = 48
  SORTS = %w[recent title author].freeze
  # "title" searches titles/authors/series (the default); "full" also digs
  # through descriptions and the Calibre-extracted text; "semantic" uses
  # the embedding index.
  SEARCH_MODES = %w[title full semantic].freeze
  # ?category= sentinel for "no category at all" (nil/blank in the DB) —
  # distinct from the param being absent, so the Shelves nav can link to
  # it like any other shelf.
  UNCATEGORIZED = "uncategorized"

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
      # An exact category wins over a root filter when both are given.
      @category = params[:category].presence
      @category_root = @category ? nil : params[:category_root].presence

      scope = Book.all
      scope = scope.where(author: @author) if @author
      scope = scope.where(series: @series) if @series
      scope = scope.where(id: BookFile.where(format: @format).select(:book_id)) if @format
      scope = scope.where(published_year: @year) if @year
      scope = scope.where(language: @language) if @language
      scope = scope.where(created_at: @added.all_day) if @added
      scope = if @category == UNCATEGORIZED
        scope.where(category: [ nil, "" ])
      elsif @category
        scope.in_category(@category)
      elsif @category_root
        scope.in_category_root(@category_root)
      else
        scope
      end
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
      # :conversions is preloaded alongside :book_files so the shelf's
      # failed-conversion badge (Book#conversion_failed_without_deliverable?)
      # never N+1s across a page of up to PER_PAGE books.
      @books = scope.includes(:book_files, :conversions).offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

      @stats = Rails.cache.fetch("library_stats", expires_in: 10.minutes) do
        { books: Book.count, files: BookFile.count, bytes: BookFile.sum(:size) }
      end

      category_counts = Rails.cache.fetch("library_categories", expires_in: 10.minutes) do
        Book.group(:category).count
      end
      @shelves = shelves_for(category_counts)
      @inbox_count = category_counts.fetch("_inbox", 0)
      @uncategorized_count = category_counts.fetch(nil, 0) + category_counts.fetch("", 0)

      # The "keep reading" shelf is the user's main entry point back into a
      # book they're mid-way through — it used to disappear the moment any
      # filter (or a later page) was active, hiding it right when someone's
      # browsing around. It now always heads the browse view; only the
      # grid below responds to filters/paging.
      @currently_reading = Book.currently_reading(limit: 10)
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
    params.expect(book: [ :title, :author, :series, :series_index, :language, :description, :published_year, :category ])
  end

  # Turns Book.group(:category).count ("fiction/sf" => 340, "practical" => 12, …)
  # into an ordered root => subs tree for the Shelves nav. "_inbox" and
  # nil/blank (uncategorized) are their own flat rows, not roots — the
  # caller pulls those out of the raw counts directly.
  def shelves_for(counts)
    by_root = Hash.new(0)
    subs_by_root = Hash.new { |h, k| h[k] = {} }

    counts.each do |category, count|
      next if category.blank? || category == "_inbox"

      root, sub = category.split("/", 2)
      by_root[root] += count
      subs_by_root[root][sub] = count if sub
    end

    known_roots = Library::Taxonomy.categories.keys
    ordered_roots = (known_roots & by_root.keys) + (by_root.keys - known_roots).sort

    ordered_roots.map do |root|
      known_subs = Library::Taxonomy.subs_for(root).keys
      root_subs = subs_by_root[root]
      ordered_subs = (known_subs & root_subs.keys) + (root_subs.keys - known_subs).sort

      {
        key: root,
        label: Library::Taxonomy.label_for(root),
        total: by_root[root],
        subs: ordered_subs.map { |sub|
          { key: "#{root}/#{sub}", label: Library::Taxonomy.sub_label_for(root, sub), count: root_subs[sub] }
        }
      }
    end
  end
end
