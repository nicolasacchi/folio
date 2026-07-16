# Derives books.category ("category" or "category/subcategory") from a
# scanned file's absolute path — the directory tree is the taxonomy, see
# docs/library-taxonomy.yml. Pure/stateless: no DB, no disk access beyond
# the path string itself.
module Library::Category
  module_function

  def from_path(path, roots:, depth: default_depth)
    depth = depth.to_i.clamp(1, 2)
    path = path.to_s

    root = roots.map { |candidate| candidate.to_s.chomp("/") }.find { |candidate| path.start_with?("#{candidate}/") }
    return nil unless root

    parts = path.delete_prefix("#{root}/").split("/")
    return nil if parts.empty?

    return "_inbox" if parts.first == "_inbox"
    return nil if parts.first.start_with?("_", ".")

    # Drop the filename; whatever dirs remain are category segments
    # followed by the author dir (and, for Calibre libraries, a "Title
    # (id)" leaf below that) — take at most `depth` segments, but only once
    # there's at least the author dir below them. A loose file directly
    # under the category segments still maps to those segments.
    dirs = parts[0..-2]
    return nil if dirs.empty?

    dirs.size >= depth ? dirs.first(depth).join("/") : dirs.first
  end

  def default_depth
    ENV.fetch("CATEGORY_DEPTH", "2").to_i.clamp(1, 2)
  end
end
