class BooksController < ApplicationController
  before_action :set_book, only: [ :show, :edit, :update, :destroy, :cover, :download, :reindex, :unindex ]

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

  # Over-fetch each ranked list before RRF fusion so the fused, deduped
  # top SEMANTIC_RESULTS still has that many results even when the two
  # lists don't fully overlap.
  SEMANTIC_RESULTS = 24

  def index
    @query = params[:q].to_s.strip
    if @query.present?
      @semantic_available = Library::Embeddings.available? &&
        (Library::Embeddings.count.positive? || Library::Embeddings.chunk_count.positive?)
      @mode = SEARCH_MODES.include?(params[:mode]) ? params[:mode] : "title"
      @mode = "title" if @mode == "semantic" && !@semantic_available
      if @mode == "semantic"
        @semantic_books, @semantic_snippets = hybrid_search(@query)
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
      # grid below responds to filters/paging. Merges web + Kindle progress.
      @currently_reading = Book.keep_reading_for(Current.user, limit: 10)
    end
  end

  def show
    @conversions = @book.conversions.order(created_at: :desc).limit(10)
    @similar = similar_books
    preferred_id = Current.user.preferred_device_id
    devices = Device.physical.order(:name).to_a
    if preferred_id && (preferred = devices.find { |d| d.id == preferred_id })
      devices = [ preferred ] + devices.reject { |d| d.id == preferred_id }
    end
    @devices = devices
    @preferred_device_id = preferred_id
    @deliveries = @book.deliveries.index_by(&:device_id)
    @annotations = @book.annotations.with_content.includes(:device).recent.limit(100)
    @vocab_entries = @book.vocab_entries.where(user: Current.user).includes(:book).recent.limit(50)
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
    # ?raw=1 bypasses the OCR companion for whoever specifically wants the
    # untouched scan (e.g. to re-run OCR elsewhere) — everyone else gets
    # the text layer for free once one exists, same as the web reader.
    path = params[:raw].present? ? file&.absolute_path : file&.read_source_path
    if file.nil? || !File.exist?(path)
      return redirect_to @book, alert: "File not available."
    end

    send_file path, filename: file.filename, type: "application/octet-stream"
  end

  # Full-text extraction is opt-in per book (the search DB hit 20GB
  # indexing every book unconditionally, and its writes hung the
  # single-threaded indexing worker): this flips the flag on and queues
  # the extraction for this one book on demand.
  def reindex
    @book.update!(fulltext_enabled: true)
    IndexBookJob.perform_later(@book.id)
    redirect_to @book, notice: "Full-text indexing queued."
  end

  # Flips the flag off and re-runs the job so it rewrites the search row
  # with the fulltext cleared (stored fulltext + has_fulltext), and (via
  # IndexBookJob's had_fulltext check) triggers one embed run that clears
  # this book's chunk vectors too.
  def unindex
    @book.update!(fulltext_enabled: false)
    IndexBookJob.perform_later(@book.id)
    redirect_to @book, notice: "Removing from search index…"
  end

  private

  # "meaning" search: fuses FTS (BM25, scope: :all so it also digs through
  # descriptions and extracted fulltext) with chunk-vector results via
  # Reciprocal Rank Fusion (Library::HybridSearch.fuse), so a query
  # benefits from both exact-term matches and semantic similarity to a
  # passage buried inside a book. Degrades in stages: no chunk vectors
  # indexed yet for anything the vector side would have found -> falls
  # back to the coarser book-level (metadata-only) vector; only reached at
  # all once @semantic_available has confirmed Library::Embeddings is
  # available (see #index) — embeddings being unavailable entirely routes
  # the request to plain FTS ("title" mode) before this method runs.
  #
  # Returns [books_in_fused_order, { book_id => snippet }] — the snippet
  # is the FTS match highlight where there is one, else the nearest
  # matching chunk's text, shown in the view as a "why this result" line.
  def hybrid_search(query, limit: SEMANTIC_RESULTS)
    fts_hits = BookSearch.search(query, scope: :all, limit: limit)
    fts_ids = fts_hits.map { |hit| hit[:book_id] }
    snippets = fts_hits.each_with_object({}) { |hit, acc| acc[hit[:book_id]] = hit[:snippet] if hit[:snippet].present? }

    vector_hits = Library::Embeddings.nearest_chunks(text: query, limit: limit)
    vector_hits = Library::Embeddings.nearest(text: query, limit: limit).map { |id, distance| [ id, distance, nil ] } if vector_hits.empty?
    vector_ids = vector_hits.map(&:first)
    vector_hits.each { |id, _distance, snippet| snippets[id] ||= snippet if snippet.present? }

    fused_ids = Library::HybridSearch.fuse(fts_ids, vector_ids).first(limit)
    # Single batched load, ordered to match the fused ranking (not
    # whatever order the DB happens to return `WHERE id IN (...)` rows in).
    books = Book.includes(:book_files).where(id: fused_ids).index_by(&:id)
    [ fused_ids.filter_map { |id| books[id] }, snippets ]
  end

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
