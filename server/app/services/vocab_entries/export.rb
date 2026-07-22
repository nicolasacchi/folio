# CSV/Anki-TSV rendering for a VocabEntry scope — shared by
# VocabEntriesController#export so each format is one well-named method
# with no controller ceremony mixed in. Both iterate the scope directly
# (already `.includes(:book)`'d by the caller) rather than building an
# intermediate array of hashes first, so memory stays bounded to one row
# at a time regardless of how large the notebook gets.
module VocabEntries
  module Export
    module_function

    CSV_HEADERS = [ "Word", "Lemma", "Lang", "Book", "Context", "Gloss", "Date" ].freeze

    def csv(entries)
      CSV.generate(headers: true) do |csv|
        csv << CSV_HEADERS
        entries.each do |entry|
          csv << [
            entry.word,
            entry.lemma,
            entry.lang,
            entry.book&.title,
            entry.context,
            entry.gloss,
            entry.created_at&.to_date&.iso8601
          ]
        end
      end
    end

    # Anki's plain-text "Basic" note import format: tab-separated
    # front/back, one note per line, no header row (Anki's importer treats
    # every line as a note unless told otherwise — a header row would just
    # get imported as a bogus card). Front is the tapped word plus its
    # dictionary lemma when they differ (e.g. "running (run)"); back is the
    # gloss plus the captured sentence, so the card is self-contained.
    def anki_tsv(entries)
      lines = entries.filter_map do |entry|
        front = entry.lemma.present? && entry.lemma != entry.word ? "#{entry.word} (#{entry.lemma})" : entry.word
        back = [ entry.gloss, entry.context ].compact_blank.join("<br>")
        next if front.blank?

        [ sanitize(front), sanitize(back) ].join("\t")
      end
      lines.join("\n")
    end

    # Anki's TSV importer treats a literal tab or newline inside a field as
    # a column/row separator, so either would silently corrupt the import
    # (a stray tab splits one card into two ragged columns) — collapse
    # both to spaces rather than escaping, which Anki's plain-TSV importer
    # doesn't support anyway.
    def sanitize(text)
      text.to_s.gsub(/[\t\r\n]+/, " ").strip
    end
  end
end
