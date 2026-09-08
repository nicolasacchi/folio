# Read-only OPDS 1.2 Atom feeds: the root navigation feed, paginated
# acquisition feeds (all books / new / by author / by series / by
# category / search), the single-entry document, and the OpenSearch
# description. Downloads (file/cover/thumbnail) live in
# Opds::DownloadsController — see that file for why they're split out.
module Opds
  class CatalogController < BaseController
    before_action :set_book, only: :entry

    def root
      @updated = Book.maximum(:updated_at) || Time.current
      render formats: :atom, content_type: Opds::ContentTypes::NAVIGATION
    end

    def books
      scope = available_books.order(created_at: :desc, id: :desc)
      items, total, page, last_page = paginate(scope)
      render_feed(
        id: "urn:folio:opds:books", title: "All books",
        items: items, total: total, page: page, last_page: last_page,
        self_url: ->(n) { opds_books_url(page: n) }
      )
    end

    def new_books
      scope = available_books.order(created_at: :desc, id: :desc)
      items, total, page, last_page = paginate(scope)
      render_feed(
        id: "urn:folio:opds:new", title: "Recently added",
        items: items, total: total, page: page, last_page: last_page,
        self_url: ->(n) { opds_new_books_url(page: n) }
      )
    end

    # The three navigation indexes below each run a DISTINCT ... ORDER BY
    # lower(...) pluck over the whole books table per request. They get the
    # same treatment as the web index's library_categories cache
    # (BooksController#index): TTL-only invalidation at 10 minutes, no
    # explicit expiry anywhere in the app, so OPDS and web go stale — and
    # refresh — consistently.

    def authors
      @updated = Book.maximum(:updated_at) || Time.current
      @authors = Rails.cache.fetch("opds_authors", expires_in: 10.minutes) do
        available_books.where.not(author: [ nil, "" ]).distinct.order(Arel.sql("lower(author)")).pluck(:author)
      end
      render formats: :atom, content_type: Opds::ContentTypes::NAVIGATION
    end

    def author
      name = params[:name]
      scope = available_books.where(author: name).order(Arel.sql("lower(title)"), :id)
      items, total, page, last_page = paginate(scope)
      render_feed(
        id: "urn:folio:opds:author:#{name}", title: name,
        items: items, total: total, page: page, last_page: last_page,
        self_url: ->(n) { opds_author_url(name: name, page: n) }
      )
    end

    def series_index
      @updated = Book.maximum(:updated_at) || Time.current
      @series_list = Rails.cache.fetch("opds_series", expires_in: 10.minutes) do
        available_books.where.not(series: [ nil, "" ]).distinct.order(Arel.sql("lower(series)")).pluck(:series)
      end
      render formats: :atom, content_type: Opds::ContentTypes::NAVIGATION
    end

    def series
      name = params[:name]
      # Reading order, not recency — same as the web's series view.
      scope = available_books.where(series: name).order(:series_index, :id)
      items, total, page, last_page = paginate(scope)
      render_feed(
        id: "urn:folio:opds:series:#{name}", title: name,
        items: items, total: total, page: page, last_page: last_page,
        self_url: ->(n) { opds_series_url(name: name, page: n) }
      )
    end

    def categories
      @updated = Book.maximum(:updated_at) || Time.current
      @categories = Rails.cache.fetch("opds_categories", expires_in: 10.minutes) do
        available_books.where.not(category: [ nil, "" ]).distinct.order(:category).pluck(:category)
      end
      render formats: :atom, content_type: Opds::ContentTypes::NAVIGATION
    end

    def category
      path = params[:path]
      # Leaf categories are "root/sub"; a bare root should also surface
      # every book filed under one of its subs (mirrors Book.in_category_root,
      # the same rule BooksController's shelf filter uses).
      scope = path.include?("/") ? available_books.in_category(path) : available_books.in_category_root(path)
      items, total, page, last_page = paginate(scope.order(Arel.sql("lower(title)"), :id))
      render_feed(
        id: "urn:folio:opds:category:#{path}", title: Library::Taxonomy.label_for(path) || path,
        items: items, total: total, page: page, last_page: last_page,
        self_url: ->(n) { opds_category_url(path: path, page: n) }
      )
    end

    def search
      @query = params[:q].to_s.strip
      hits = @query.present? ? Book.search(@query, scope: :metadata) : []
      deliverable_ids = BookFile.available.where(book_id: hits.map { |hit| hit.book.id }).distinct.pluck(:book_id).to_set
      ranked_books = hits.filter_map { |hit| hit.book if deliverable_ids.include?(hit.book.id) }

      total = ranked_books.size
      last_page = [ (total / PER_PAGE.to_f).ceil, 1 ].max
      page = [ [ params[:page].to_i, 1 ].max, last_page ].min
      page_ids = ranked_books[(page - 1) * PER_PAGE, PER_PAGE].to_a.map(&:id)
      books_by_id = Book.includes(:book_files).where(id: page_ids).index_by(&:id)
      items = page_ids.map { |id| books_by_id[id] }

      render_feed(
        id: "urn:folio:opds:search:#{@query}", title: "Search results for “#{@query}”",
        items: items, total: total, page: page, last_page: last_page,
        self_url: ->(n) { opds_search_url(q: @query, page: n) }
      )
    end

    def opensearch
      render formats: :xml, content_type: Opds::ContentTypes::OPENSEARCH
    end

    def entry
      render formats: :atom, content_type: Opds::ContentTypes::ENTRY
    end

    private

    def set_book
      @book = available_books.find_by!(public_id: params[:public_id])
    end

    def paginate(scope)
      total = scope.count
      last_page = [ (total / PER_PAGE.to_f).ceil, 1 ].max
      page = [ [ params[:page].to_i, 1 ].max, last_page ].min
      items = scope.includes(:book_files).offset((page - 1) * PER_PAGE).limit(PER_PAGE)
      [ items, total, page, last_page ]
    end

    def render_feed(id:, title:, items:, total:, page:, last_page:, self_url:, up_url: nil)
      @feed_id = id
      @feed_title = title
      @updated = Book.maximum(:updated_at) || Time.current
      @items = items
      @total = total
      @page = page
      @last_page = last_page
      @per_page = PER_PAGE
      @self_url = self_url
      @up_url = up_url || opds_root_url
      render "opds/catalog/acquisition_feed", formats: :atom, content_type: Opds::ContentTypes::ACQUISITION
    end
  end
end
