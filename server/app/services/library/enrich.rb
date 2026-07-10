require "net/http"

# Fills the blanks in a book's metadata (description, published year,
# missing cover) from public catalog APIs — Komga-style enrichment. Only
# blank fields are ever written; user edits and embedded metadata always
# win. Records the outcome in enriched_at/enrichment_source so the batch
# doesn't retry books that found no match.
module Library::Enrich
  MAX_COVER_BYTES = 5.megabytes

  module_function

  def providers
    [ Library::Enrich::OpenLibrary, Library::Enrich::GoogleBooks ]
  end

  # => :enriched | :no_match | :skip
  def call(book)
    return :skip unless needs_enrichment?(book)

    providers.each do |provider|
      data = provider.lookup(title: book.title, author: book.author)
      next if data.nil?

      apply(book, data, provider)
      return :enriched
    end

    book.update_columns(enriched_at: Time.current, enrichment_source: "none")
    :no_match
  end

  def needs_enrichment?(book)
    book.description.blank? || book.published_year.blank? || !book.cover?
  end

  def apply(book, data, provider)
    updates = {}
    updates[:description] = data[:description].to_s.strip.byteslice(0, 5000).scrub("") if book.description.blank? && data[:description].present?
    updates[:published_year] = data[:published_year] if book.published_year.blank? && data[:published_year].present?
    book.update!(**updates) if updates.any?
    book.update_columns(enriched_at: Time.current, enrichment_source: provider.key)

    fetch_cover(book, data[:cover_url]) if !book.cover? && data[:cover_url].present?

    if updates[:description]
      BookSearch.index_book!(book)
      EmbedBookJob.perform_later(book.id) if Library::Embeddings.available?
    end
  end

  def fetch_cover(book, url)
    bytes = get(url, limit: MAX_COVER_BYTES)
    return if bytes.nil? || bytes.bytesize < 1_000 # provider "no cover" placeholders are tiny

    FileUtils.mkdir_p(Library.covers_root)
    File.binwrite(Library.cover_path(book), bytes)
  rescue StandardError
    nil
  end

  # Small shared HTTP GET with redirects, timeouts and a size cap.
  def get(url, limit: 2.megabytes, redirects: 3)
    uri = URI.parse(url)
    return nil unless uri.is_a?(URI::HTTP)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                               open_timeout: 10, read_timeout: 20) do |http|
      http.get(uri.request_uri, { "User-Agent" => "Folio/1.0 (personal library; ruby)" })
    end

    case response
    when Net::HTTPRedirection
      redirects.positive? ? get(response["location"], limit: limit, redirects: redirects - 1) : nil
    when Net::HTTPSuccess
      body = response.body.to_s
      body.bytesize <= limit ? body : nil
    end
  rescue StandardError
    nil
  end

  # Both providers use this to reject look-alike results: enough word
  # overlap in the title, and the author's surname somewhere in the
  # candidate's author list when we know it.
  def plausible_match?(book_title:, book_author:, found_title:, found_authors:)
    ours = tokens(book_title)
    theirs = tokens(found_title)
    return false if ours.empty? || theirs.empty?

    overlap = (ours & theirs).size.to_f / ours.size
    return false if overlap < 0.5

    if book_author.present? && found_authors.present?
      surname = tokens(book_author.split(/[,;&]/).first).last
      return found_authors.any? { |candidate| tokens(candidate).include?(surname) } if surname
    end
    true
  end

  def tokens(value)
    value.to_s.downcase.scan(/[[:alnum:]]+/).reject { |token| token.size < 2 }
  end
end
