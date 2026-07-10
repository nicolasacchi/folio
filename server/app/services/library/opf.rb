# Reads the subset of a Calibre metadata.opf (OPF 2.0 Dublin Core plus
# calibre:* meta tags) that maps onto Book attributes. Parsing the sidecar
# is orders of magnitude cheaper than shelling out to ebook-meta per file,
# which matters when scanning a multi-thousand-book Calibre library.
module Library::Opf
  DC = { "dc" => "http://purl.org/dc/elements/1.1/" }.freeze

  module_function

  def parse(path)
    doc = Nokogiri::XML(File.read(path))
    meta = {}

    title = doc.at_xpath("//dc:title", DC)&.text.to_s.strip
    meta[:title] = title if title.present?

    authors = doc.xpath("//dc:creator", DC).map { |node| node.text.strip }.reject(&:blank?)
    meta[:author] = authors.join(", ") if authors.any?

    series = calibre_meta(doc, "calibre:series")
    if series.present?
      meta[:series] = series
      index = calibre_meta(doc, "calibre:series_index")
      meta[:series_index] = index.to_f if index.present?
    end

    language = doc.at_xpath("//dc:language", DC)&.text.to_s.strip
    meta[:language] = language if language.present?

    description = doc.at_xpath("//dc:description", DC)&.text.to_s
    meta[:description] = Calibre.strip_html(description) if description.present?

    date = doc.at_xpath("//dc:date", DC)&.text.to_s
    meta[:published_year] = Regexp.last_match(1).to_i if date =~ /\A(\d{4})/

    meta
  rescue StandardError
    {}
  end

  # Calibre writes <meta name="calibre:series" content="…"/>; match on the
  # attribute rather than fighting OPF namespace variations.
  def calibre_meta(doc, name)
    doc.at_xpath(%(//*[@name="#{name}"]/@content))&.text.to_s.strip
  end
end
