# Thin wrapper around the Calibre CLI tools (ebook-convert, ebook-meta),
# which do all format conversion, metadata and text extraction work.
module Calibre
  class Error < StandardError; end

  module_function

  def available?
    @available = system("ebook-convert", "--version", out: File::NULL, err: File::NULL) if @available.nil?
    @available
  end

  def convert(source, target, options: [])
    run("ebook-convert", source.to_s, target.to_s, *options)
    target
  end

  # Parses `ebook-meta` output into { title:, author:, series:, series_index:,
  # language:, description:, published_year: }. Missing keys are absent.
  def metadata(path)
    output = run("ebook-meta", path.to_s)
    fields = parse_meta_output(output)
    meta = {}
    meta[:title] = fields["Title"] if present?(fields["Title"])
    meta[:author] = clean_author(fields["Author(s)"]) if present?(fields["Author(s)"])
    if present?(fields["Series"])
      series, index = parse_series(fields["Series"])
      meta[:series] = series
      meta[:series_index] = index if index
    end
    meta[:language] = fields["Languages"].to_s.split(",").first&.strip if present?(fields["Languages"])
    meta[:description] = strip_html(fields["Comments"]) if present?(fields["Comments"])
    if present?(fields["Published"]) && fields["Published"] =~ /\A(\d{4})/
      meta[:published_year] = Regexp.last_match(1).to_i
    end
    meta
  end

  def extract_cover(path, destination)
    run("ebook-meta", path.to_s, "--get-cover", destination.to_s)
    File.exist?(destination) && File.size(destination).positive?
  rescue Error
    false
  end

  # Converts to plain text for the search index. Returns "" when the format
  # has no extractable text (e.g. image-only comics).
  def extract_text(path)
    Dir.mktmpdir("calibre-text") do |dir|
      target = File.join(dir, "fulltext.txt")
      run("ebook-convert", path.to_s, target)
      File.read(target, encoding: "UTF-8", invalid: :replace, undef: :replace)
    end
  rescue Error
    ""
  end

  def run(*command)
    stdout, stderr, status = Open3.capture3(*command)
    unless status.success?
      raise Error, "#{command.first} failed (#{status.exitstatus}): #{stderr.presence || stdout}".byteslice(0, 4000)
    end
    stdout
  end

  def parse_meta_output(output)
    fields = {}
    current = nil
    output.each_line do |line|
      if line =~ /\A([A-Z][^:]{0,30}?)\s*:\s(.*)\z/m
        current = Regexp.last_match(1).strip
        fields[current] = Regexp.last_match(2).strip
      elsif current
        fields[current] << "\n" << line.strip
      end
    end
    fields
  end

  def clean_author(value)
    # "Jane Doe [Doe, Jane]" -> "Jane Doe"; keep multiple authors joined.
    value.gsub(/\s*\[[^\]]*\]/, "").strip.delete_suffix(",")
  end

  def parse_series(value)
    if value =~ /\A(.*)\s+#([\d.]+)\z/
      [ Regexp.last_match(1).strip, Regexp.last_match(2).to_f ]
    else
      [ value.strip, nil ]
    end
  end

  def strip_html(value)
    value.gsub(/<[^>]+>/, " ").squeeze(" ").strip
  end

  def present?(value)
    value.to_s.strip != "" && value.to_s.strip.downcase != "unknown"
  end
end
