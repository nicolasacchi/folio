xml.instruct!
xml.feed("xmlns" => "http://www.w3.org/2005/Atom") do
  xml.id "urn:folio:opds:root"
  xml.title "Folio Library"
  xml.updated @updated.utc.iso8601
  xml.author do
    xml.name "Folio"
    xml.uri root_url
  end

  xml.link rel: "self", href: opds_root_url, type: Opds::ContentTypes::NAVIGATION
  xml.link rel: "start", href: opds_root_url, type: Opds::ContentTypes::NAVIGATION
  xml.link rel: "search", href: opds_opensearch_url, type: Opds::ContentTypes::OPENSEARCH

  xml.entry do
    xml.id "urn:folio:opds:new"
    xml.title "Recently added"
    xml.updated @updated.utc.iso8601
    xml.content "Books ordered by date added to Folio.", type: "text"
    xml.link rel: "http://opds-spec.org/sort/new", href: opds_new_books_url, type: Opds::ContentTypes::ACQUISITION
  end

  xml.entry do
    xml.id "urn:folio:opds:books"
    xml.title "All books"
    xml.updated @updated.utc.iso8601
    xml.content "Entire library, newest first.", type: "text"
    xml.link rel: "subsection", href: opds_books_url, type: Opds::ContentTypes::ACQUISITION
  end

  xml.entry do
    xml.id "urn:folio:opds:authors"
    xml.title "By author"
    xml.updated @updated.utc.iso8601
    xml.content "Browse the library by author.", type: "text"
    xml.link rel: "subsection", href: opds_authors_url, type: Opds::ContentTypes::NAVIGATION
  end

  xml.entry do
    xml.id "urn:folio:opds:series"
    xml.title "By series"
    xml.updated @updated.utc.iso8601
    xml.content "Browse the library by series.", type: "text"
    xml.link rel: "subsection", href: opds_series_index_url, type: Opds::ContentTypes::NAVIGATION
  end

  xml.entry do
    xml.id "urn:folio:opds:categories"
    xml.title "By category"
    xml.updated @updated.utc.iso8601
    xml.content "Browse the library by shelf / category.", type: "text"
    xml.link rel: "subsection", href: opds_categories_url, type: Opds::ContentTypes::NAVIGATION
  end
end
