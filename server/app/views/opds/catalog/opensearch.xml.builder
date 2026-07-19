# OpenSearch 1.1 description document (OPDS 1.2 §3). The Url's `template`
# is built by string interpolation, not url_for/opds_search_url(q: …) —
# the {searchTerms}/{startPage?} tokens must reach the client literal;
# routing through url_for would percent-encode the braces and break them.
xml.instruct!
xml.tag!(
  "OpenSearchDescription",
  xmlns: "http://a9.com/-/spec/opensearch/1.1/",
  "xmlns:atom" => "http://www.w3.org/2005/Atom"
) do
  xml.ShortName "Folio"
  xml.Description "Search the Folio library"
  xml.InputEncoding "UTF-8"
  xml.OutputEncoding "UTF-8"
  xml.Url type: Opds::ContentTypes::ACQUISITION,
    template: "#{opds_search_url}?q={searchTerms}&page={startPage?}"
end
