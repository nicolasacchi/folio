xml.instruct!
xml.feed("xmlns" => "http://www.w3.org/2005/Atom") do
  xml.id "urn:folio:opds:categories"
  xml.title "By category"
  xml.updated @updated.utc.iso8601
  xml.author { xml.name "Folio" }

  xml.link rel: "self", href: opds_categories_url, type: Opds::ContentTypes::NAVIGATION
  xml.link rel: "start", href: opds_root_url, type: Opds::ContentTypes::NAVIGATION
  xml.link rel: "up", href: opds_root_url, type: Opds::ContentTypes::NAVIGATION
  xml.link rel: "search", href: opds_opensearch_url, type: Opds::ContentTypes::OPENSEARCH

  @categories.each do |path|
    xml.entry do
      xml.id "urn:folio:opds:category:#{path}"
      xml.title Library::Taxonomy.label_for(path) || path
      xml.updated @updated.utc.iso8601
      xml.link rel: "subsection", href: opds_category_url(path: path), type: Opds::ContentTypes::ACQUISITION
    end
  end
end
