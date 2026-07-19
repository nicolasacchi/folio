module DuplicatesHelper
  # Confirmation text for a group's "Merge others into this" button: the
  # format union the merged book ends up with, and which formats collide
  # (Library::MergeBooks leaves those where they are rather than deleting or
  # overwriting a managed file) — so the confirm dialog shows the actual
  # result before the destructive merge runs, not just a bare count.
  #
  # A full preview page (a GET step rendering the same info before the
  # merge, rather than folding it into the confirm() text) would need its
  # own route/view and a way to re-POST the original target/source ids —
  # more surface than this pass covers; this is the confirm-summary
  # fallback the merge control already had, made accurate instead of
  # generic. Reads off the group's preloaded book_files, never queries.
  def merge_preview_summary(group, target)
    sources = group - [ target ]
    seen = target.book_files.map(&:format)
    conflicts = []

    sources.each do |source|
      source.book_files.each do |file|
        if seen.include?(file.format)
          conflicts << file.format
        else
          seen << file.format
        end
      end
    end

    summary = "Merge #{pluralize(sources.size, 'other edition')} into “#{target.title}”? " \
              "Result: #{seen.uniq.sort.map(&:upcase).join(', ')}."
    if conflicts.any?
      list = conflicts.uniq.sort.map(&:upcase).join(", ")
      summary += " #{list} #{conflicts.uniq.size == 1 ? 'is' : 'are'} on more than one edition — the extra copy stays put."
    end
    summary
  end
end
