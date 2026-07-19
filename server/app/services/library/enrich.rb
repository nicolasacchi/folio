require "net/http"
require "ipaddr"
require "resolv"

# Fills the blanks in a book's metadata (description, published year,
# missing cover) from public catalog APIs — Komga-style enrichment. Only
# blank fields are ever written; user edits and embedded metadata always
# win. Records the outcome in enriched_at/enrichment_source so the batch
# doesn't retry books that found no match.
module Library::Enrich
  MAX_COVER_BYTES = 5.megabytes

  # Ranges IPAddr's own #private?/#loopback?/#link_local? don't already
  # catch, but that still have no business being an "external provider"
  # address (SSRF guard in #get — see there for why this matters).
  RESERVED_IP_RANGES = [
    IPAddr.new("0.0.0.0/8"),       # "this network"
    IPAddr.new("100.64.0.0/10"),   # carrier-grade NAT
    IPAddr.new("192.0.0.0/24"),    # IETF protocol assignments
    IPAddr.new("192.0.2.0/24"),    # TEST-NET-1
    IPAddr.new("198.18.0.0/15"),   # benchmarking
    IPAddr.new("198.51.100.0/24"), # TEST-NET-2
    IPAddr.new("203.0.113.0/24"),  # TEST-NET-3
    IPAddr.new("224.0.0.0/4"),     # multicast
    IPAddr.new("240.0.0.0/4"),     # reserved
    IPAddr.new("::/128")           # unspecified address
  ].freeze

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
    # Catalog records sometimes carry junk dates (Open Library will happily
    # report year 101); only accept plausible publication years.
    year = data[:published_year].to_i
    updates[:published_year] = year if book.published_year.blank? && year.between?(1000, Date.current.year + 1)
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

  # Small shared HTTP GET with redirects, timeouts and a size cap. SSRF
  # guard: a provider response (or a compromised/malicious provider) could
  # point us at an internal address via the initial URL or a redirect —
  # every hop is checked here before we connect.
  def get(url, limit: 2.megabytes, redirects: 3)
    uri = URI.parse(url)
    return nil unless uri.is_a?(URI::HTTP) # scheme must be http or https
    unless public_host?(uri.host)
      Rails.logger.warn("Library::Enrich#get refused #{uri.scheme}://#{uri.host} (private/reserved address)")
      return nil
    end

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

  # Resolves +host+ and rejects it unless every address it resolves to is a
  # routable public IP. Checking the resolved IP (rather than the hostname)
  # is deliberate — providers rotate CDN hostnames, but a private/loopback/
  # link-local/reserved *address* is never legitimate for an external API
  # call regardless of what name pointed at it.
  def public_host?(host)
    addresses = Resolv.getaddresses(host)
    return false if addresses.empty?

    addresses.all? { |address| !blocked_ip?(IPAddr.new(address)) }
  rescue IPAddr::Error, Resolv::ResolvError, Resolv::ResolvTimeout
    false
  end

  def blocked_ip?(ip)
    ip = ip.native if ip.ipv4_mapped?
    ip.private? || ip.loopback? || ip.link_local? || RESERVED_IP_RANGES.any? { |range| range.include?(ip) }
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
