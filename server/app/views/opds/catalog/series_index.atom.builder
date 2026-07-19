xml.instruct!
xml.feed("xmlns" => "http://www.w3.org/2005/Atom") do
  xml.id "urn:folio:opds:series"
  xml.title "By series"
  xml.updated @updated.utc.iso8601
  xml.author { xml.name "Folio" }

  xml.link rel: "self", href: opds_series_index_url, type: Opds::ContentTypes::NAVIGATION
  xml.link rel: "start", href: opds_root_url, type: Opds::ContentTypes::NAVIGATION
  xml.link rel: "up", href: opds_root_url, type: Opds::ContentTypes::NAVIGATION
  xml.link rel: "search", href: opds_opensearch_url, type: Opds::ContentTypes::OPENSEARCH

  @series_list.each do |name|
    xml.entry do
      xml.id "urn:folio:opds:series:#{name}"
      xml.title name
      xml.updated @updated.utc.iso8601
      xml.link rel: "subsection", href: opds_series_url(name: name), type: Opds::ContentTypes::ACQUISITION
    end
  end
end
