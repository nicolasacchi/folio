# Shared by CatalogController#books/#new_books/#author/#series/#category/
# #search — they all render this same template (via render_feed) with
# different @feed_id/@feed_title/@items/@self_url, so the RFC 5005 paging
# chrome and OpenSearch response elements only need writing once.
xml.instruct!
xml.feed(
  "xmlns" => "http://www.w3.org/2005/Atom",
  "xmlns:dc" => "http://purl.org/dc/terms/",
  "xmlns:opds" => "http://opds-spec.org/2010/catalog",
  "xmlns:opensearch" => "http://a9.com/-/spec/opensearch/1.1/"
) do
  xml.id @feed_id
  xml.title @feed_title
  xml.updated @updated.utc.iso8601
  xml.author { xml.name "Folio" }

  xml.link rel: "self", href: @self_url.call(@page), type: Opds::ContentTypes::ACQUISITION
  xml.link rel: "start", href: opds_root_url, type: Opds::ContentTypes::NAVIGATION
  xml.link rel: "up", href: @up_url, type: Opds::ContentTypes::NAVIGATION
  xml.link rel: "search", href: opds_opensearch_url, type: Opds::ContentTypes::OPENSEARCH

  # RFC 5005 paged-feed links (OPDS 1.2 §2.4).
  xml.link rel: "first", href: @self_url.call(1), type: Opds::ContentTypes::ACQUISITION
  xml.link rel: "last", href: @self_url.call(@last_page), type: Opds::ContentTypes::ACQUISITION
  xml.link rel: "previous", href: @self_url.call(@page - 1), type: Opds::ContentTypes::ACQUISITION if @page > 1
  xml.link rel: "next", href: @self_url.call(@page + 1), type: Opds::ContentTypes::ACQUISITION if @page < @last_page

  xml.tag!("opensearch:totalResults", @total)
  xml.tag!("opensearch:itemsPerPage", @per_page)
  xml.tag!("opensearch:startIndex", @total.zero? ? 0 : ((@page - 1) * @per_page) + 1)

  @items.each do |book|
    xml << render(partial: "opds/catalog/entry", locals: { book: book })
  end
end
