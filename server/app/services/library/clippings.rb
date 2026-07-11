# Parser + importer for the Kindle's "My Clippings.txt" — the only place
# the device stores the *text* of highlights and typed notes (the .sdr
# sidecars we sync carry positions only). The daemon uploads the whole
# file whenever it changes; entries are deduped by fingerprint so
# re-imports are cheap and idempotent.
#
# Entry format (UTF-8 with BOM, CRLF, "=" * 10 separators):
#
#   Il nome della rosa (Umberto Eco)
#   - La tua evidenziazione a pagina 45 | posizione 680-82 | Aggiunto il lunedì 6 luglio 2026 21:13:22
#
#   Testo evidenziato…
#   ==========
#
# English devices write "- Your Highlight on page 45 | location 680-82 |
# Added on Monday, July 6, 2026 9:13:22 PM". Both are supported.
module Library
  module Clippings
    SEPARATOR = /^={10}\s*$/
    MAX_CONTENT = 20_000

    KINDS = {
      /evidenziazione|highlight|surlignement|subrayado|marcador/i => "highlight",
      /\bnota\b|\bnote\b/i => "note",
      /segnalibro|bookmark|signet/i => "bookmark"
    }.freeze

    IT_MONTHS = {
      "gennaio" => "January", "febbraio" => "February", "marzo" => "March",
      "aprile" => "April", "maggio" => "May", "giugno" => "June",
      "luglio" => "July", "agosto" => "August", "settembre" => "September",
      "ottobre" => "October", "novembre" => "November", "dicembre" => "December"
    }.freeze
    IT_DAYS = /luned[iì]|marted[iì]|mercoled[iì]|gioved[iì]|venerd[iì]|sabato|domenica/i

    Entry = Struct.new(:raw_title, :raw_author, :kind, :page, :location_start,
      :location_end, :added_at, :content, :fingerprint, keyword_init: true)

    module_function

    # → array of Entry
    def parse(text)
      text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      text.delete_prefix!("\u{FEFF}")

      text.split(SEPARATOR).filter_map { |chunk| parse_entry(chunk) }
    end

    # Parses + persists for a device. Returns { imported:, matched:, total: }.
    def import(device, text)
      entries = parse(text)
      imported = 0

      entries.each do |entry|
        annotation = Annotation.find_or_initialize_by(device: device, fingerprint: entry.fingerprint)
        next unless annotation.new_record?

        annotation.assign_attributes(
          raw_title: entry.raw_title, raw_author: entry.raw_author,
          kind: entry.kind, page: entry.page,
          location_start: entry.location_start, location_end: entry.location_end,
          added_at: entry.added_at, content: entry.content,
          book: match_book(entry.raw_title, entry.raw_author)
        )
        annotation.save!
        imported += 1
      rescue ActiveRecord::RecordNotUnique
        # Concurrent import of the same entry — already there, move on.
      end

      rematch_unmatched(device)
      { imported: imported, matched: device.annotations.matched.count, total: entries.size }
    end

    def parse_entry(chunk)
      lines = chunk.strip.split(/\r?\n/)
      return nil if lines.size < 2

      title_line = lines.shift.strip
      meta_line = lines.shift.to_s.strip
      return nil if title_line.blank? || !meta_line.start_with?("-")

      raw_title, raw_author = split_title(title_line)
      content = lines.join("\n").strip.byteslice(0, MAX_CONTENT).to_s.scrub

      Entry.new(
        raw_title: raw_title,
        raw_author: raw_author,
        kind: kind_of(meta_line),
        page: capture_int(meta_line, /(?:pagina|page)\s+(\d+)/i),
        location_start: capture_int(meta_line, /(?:posizione|location)\s+(\d+)/i),
        location_end: capture_int(meta_line, /(?:posizione|location)\s+\d+-(\d+)/i),
        added_at: added_at(meta_line),
        content: content.presence,
        fingerprint: Digest::SHA256.hexdigest("#{title_line}\n#{meta_line}\n#{content}")
      )
    end

    def capture_int(line, pattern)
      value = line[pattern, 1]
      value&.to_i
    end

    def split_title(line)
      if (match = line.match(/\A(.+)\s+\(([^()]+)\)\z/))
        [ match[1].strip, match[2].strip ]
      else
        [ line, nil ]
      end
    end

    def kind_of(meta_line)
      KINDS.each { |pattern, kind| return kind if meta_line.match?(pattern) }
      "highlight"
    end

    # "Aggiunto il lunedì 6 luglio 2026 21:13:22" / "Added on Monday,
    # July 6, 2026 9:13:22 PM" → Time (nil when unparseable).
    def added_at(meta_line)
      stamp = meta_line[/(?:Aggiunto il|Added on)\s+(.+)\z/i, 1]
      return nil unless stamp

      normalized = stamp.gsub(IT_DAYS, "").gsub(/,/, " ")
      IT_MONTHS.each { |it, en| normalized = normalized.gsub(/\b#{it}\b/i, en) }
      Time.zone.parse(normalized.squeeze(" ").strip)
    rescue ArgumentError
      nil
    end

    # Kindle titles usually match our catalog title exactly (both come from
    # the same file metadata). Tie-break multiple matches by author.
    def match_book(raw_title, raw_author)
      candidates = Book.where("LOWER(title) = ?", raw_title.downcase.strip).limit(10).to_a
      return candidates.first if candidates.size <= 1 || raw_author.blank?

      wanted = normalize_author(raw_author)
      candidates.find { |book| author_matches?(book.author, wanted) } || candidates.first
    end

    def rematch_unmatched(device)
      device.annotations.unmatched.find_each do |annotation|
        book = match_book(annotation.raw_title, annotation.raw_author)
        annotation.update_columns(book_id: book.id) if book
      end
    end

    def author_matches?(author, wanted)
      author.present? && normalize_author(author) == wanted
    end

    # "Eco, Umberto" and "Umberto Eco" should meet in the middle: compare
    # the sorted word set, ignoring punctuation and order.
    def normalize_author(author)
      author.to_s.downcase.scan(/[[:alnum:]]+/).sort.join(" ")
    end
  end
end
