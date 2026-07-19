# Renders one <entry>. Shared by every acquisition feed AND by the
# standalone single-entry document (entry.atom.builder) — pass
# standalone: true there so the <entry> itself carries the namespace
# declarations a bare document root needs (a nested <entry> inherits them
# from the enclosing <feed> instead). See catalog_controller.rb#entry and
# acquisition_feed.atom.builder.
#
# Builder gives every template (partials included) its own fresh
# Builder::XmlMarkup writing to its own buffer (see
# ActionView::Template::Handlers::Builder) — so a partial can't append
# into an already-open tag from its caller. Composition instead happens by
# rendering a complete, self-contained fragment here and splicing the
# resulting string into the parent with `xml << render(...)` (raw, not
# re-escaped — this fragment is already valid XML).
entry_attrs =
  if local_assigns[:standalone]
    {
      "xmlns" => "http://www.w3.org/2005/Atom",
      "xmlns:dc" => "http://purl.org/dc/terms/",
      "xmlns:opds" => "http://opds-spec.org/2010/catalog"
    }
  else
    {}
  end

xml.entry(entry_attrs) do
  xml.title book.title
  xml.id "urn:folio:book:#{book.public_id}"
  xml.updated book.updated_at.utc.iso8601
  xml.author { xml.name book.display_author }
  xml.tag!("dc:language", book.language) if book.language.present?
  xml.tag!("dc:issued", book.published_year) if book.published_year.present?

  if book.category.present?
    xml.category term: book.category, label: (Library::Taxonomy.label_for(book.category) || book.category)
  end

  if book.series.present?
    index = book.series_index
    index_label = index.nil? ? nil : (index % 1 == 0 ? index.to_i.to_s : index.to_s)
    xml.tag!("dc:subject", [ book.series, index_label && "##{index_label}" ].compact.join(" "))
  end

  xml.summary book.description.to_s.truncate(1000), type: "text" if book.description.present?

  if book.cover?
    xml.link rel: "http://opds-spec.org/image",
      href: opds_entry_cover_url(public_id: book.public_id), type: "image/jpeg"
    xml.link rel: "http://opds-spec.org/image/thumbnail",
      href: opds_entry_thumbnail_url(public_id: book.public_id), type: "image/jpeg"
  end

  xml.link rel: "alternate", href: opds_entry_url(public_id: book.public_id),
    type: Opds::ContentTypes::ENTRY, title: "Complete entry"

  # book.book_files is preloaded by the caller (CatalogController#paginate's
  # .includes(:book_files)) — .select here is an in-memory filter, not a
  # query, so this never N+1s across a page of entries.
  book.book_files.select(&:available?).sort_by(&:format).each do |book_file|
    xml.link rel: "http://opds-spec.org/acquisition",
      href: opds_entry_file_url(public_id: book.public_id, fmt: book_file.format),
      type: Opds::MimeTypes.for(book_file.format)
  end
end
