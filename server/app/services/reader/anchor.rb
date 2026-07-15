# Maps between raw byte offsets in Library::Mobi.raw_text's output (what
# KRDS `lpr`/`fpr` position strings index into) and human-locatable text
# snippets the in-browser reader (foliate-js) can search for.
#
# Pipeline, run once per book_file and cached on disk:
#   raw html bytes -> strip tags -> decode entities -> collapse whitespace
#     -> stripped_text (a UTF-8 String) + offsets (Array<Integer>, one
#        raw byte offset per stripped_text char, monotonically
#        non-decreasing so raw-offset -> stripped-index can binary-search
#        it — this one array is the "offset_map" in both directions:
#        offsets[stripped_index] for the forward direction,
#        stripped_index_for_offset(offsets, raw_offset) for the reverse).
#
# snippet_at is the Kindle -> web direction (KRDS offset -> text the
# client can search for); locate is the reverse (client selection/search
# result -> a raw offset Library::Krds.update_positions can write back).
module Reader
  module Anchor
    # Namespaced by environment so the test suite's book_file fixtures
    # (often built with deterministic, non-content-derived sha256s) can
    # never collide with a real entry cached by a running dev/production
    # server sharing the same tmp/ directory.
    CACHE_ROOT = Rails.root.join("tmp", "cache", "reader_anchor", Rails.env)

    EXACT_LENGTH = 120
    FUZZY_MIN_TOKEN = 8
    FUZZY_THRESHOLD = 0.85

    ENTITY_PATTERN = '&(?:amp|lt|gt|quot|#(\d+)|#x([0-9a-fA-F]+));'
    ENTITY_ANCHORED = /\A#{ENTITY_PATTERN}/
    ENTITY_GLOBAL = /#{ENTITY_PATTERN}/
    TAG_RE = /<[^>]*>/m
    WHITESPACE_RE = /\s/

    module_function

    # {before:, exact:, after:} stripped-text snippet anchored at the raw
    # byte offset (clamped to EOF; offsets that land inside a tag map to
    # the nearest actual text).
    def snippet_at(book_file, offset, radius: 300)
      stripped_text, offsets = load_or_build(book_file)
      return { before: "", exact: "", after: "" } if stripped_text.empty?

      start = stripped_index_for_offset(offsets, offset)
      exact_end = trim_trailing_partial_word(stripped_text, [ start + EXACT_LENGTH, stripped_text.length ].min)
      exact_end = start if exact_end < start

      before_start = trim_leading_partial_word(stripped_text, [ start - radius / 2, 0 ].max)
      after_end = trim_trailing_partial_word(stripped_text, [ exact_end + radius / 2, stripped_text.length ].min)

      {
        before: stripped_text[before_start...start].to_s,
        exact: stripped_text[start...exact_end].to_s,
        after: stripped_text[exact_end...after_end].to_s
      }
    end

    # Raw byte offset of `exact`'s start within book_file's text, or nil.
    # 1) exact substring search, disambiguated by before/after context
    #    when it isn't unique; 2) fuzzy fallback keyed on the rarest
    #    long token, accepted only above FUZZY_THRESHOLD similarity.
    def locate(book_file, exact, before: nil, after: nil)
      stripped_text, offsets = load_or_build(book_file)
      query = normalize(exact)
      return nil if query.empty? || stripped_text.empty?

      occurrences = find_all(stripped_text, query)
      index =
        if occurrences.size <= 1
          occurrences.first
        else
          disambiguate(stripped_text, query, occurrences, normalize(before.to_s), normalize(after.to_s))
        end
      return offsets[index] if index

      fuzzy_locate(stripped_text, offsets, query)
    end

    # Same normalization stripped_text was built with, applied to a plain
    # query string so the two sides are comparable.
    def normalize(text)
      text.to_s.gsub(TAG_RE, "").gsub(ENTITY_GLOBAL) { decode_entity(Regexp.last_match) }.gsub(/\s+/, " ").strip
    end

    # -- disk cache, content-addressed by book_file's sha256 -------------

    def load_or_build(book_file)
      path = cache_path(book_file.sha256)
      return Marshal.load(File.binread(path)) if File.exist?(path)

      pair = build(book_file)
      write_cache(path, pair)
      pair
    end

    def build(book_file)
      build_offset_pair(Library::Mobi.raw_text(book_file.absolute_path))
    end

    def cache_path(sha256)
      CACHE_ROOT.join("#{sha256}.bin")
    end

    def write_cache(path, pair)
      FileUtils.mkdir_p(path.dirname)
      tmp = Pathname.new("#{path}.tmp-#{SecureRandom.hex(8)}")
      File.binwrite(tmp, Marshal.dump(pair))
      File.rename(tmp, path)
    rescue SystemCallError
      nil # best-effort — a failed cache write shouldn't break anchoring
    end

    # -- building stripped_text + offsets ---------------------------------

    def build_offset_pair(raw_text)
      detagged, byte_offsets = strip_tags(raw_text.to_s.b)
      chars, char_offsets = split_chars(detagged, byte_offsets)
      decode_entities_and_collapse(chars, char_offsets)
    end

    # Removes <...> tag spans, keeping a parallel array of each surviving
    # byte's offset in the original (still-binary) raw string.
    def strip_tags(raw)
      detagged = +"".b
      offsets = []
      pos = 0
      raw.scan(TAG_RE) do
        match = Regexp.last_match
        if match.begin(0) > pos
          detagged << raw.byteslice(pos, match.begin(0) - pos)
          offsets.concat((pos...match.begin(0)).to_a)
        end
        pos = match.end(0)
      end
      if pos < raw.bytesize
        detagged << raw.byteslice(pos, raw.bytesize - pos)
        offsets.concat((pos...raw.bytesize).to_a)
      end
      [ detagged, offsets ]
    end

    # Regroups the (still-binary) detagged bytes into UTF-8 characters —
    # each character's own offset is its first byte's original offset.
    # each_char groups multibyte sequences correctly even over invalid
    # UTF-8 (it falls back to one byte per "char" there), so the byte
    # accounting stays correct either way.
    def split_chars(detagged, byte_offsets)
      text = detagged.dup.force_encoding("UTF-8")
      chars = []
      offsets = []
      cursor = 0
      text.each_char do |char|
        chars << char
        offsets << byte_offsets[cursor]
        cursor += char.bytesize
      end
      [ chars, offsets ]
    end

    # Decodes HTML entities (each always collapses to exactly one output
    # char) and collapses whitespace runs to a single space, in one pass
    # over the per-char arrays from split_chars.
    def decode_entities_and_collapse(chars, offsets)
      out = +""
      out_offsets = []
      i = 0
      n = chars.size
      last_was_space = false

      while i < n
        lookahead = chars[i, [ 12, n - i ].min].join
        if (match = ENTITY_ANCHORED.match(lookahead))
          out << decode_entity(match)
          out_offsets << offsets[i]
          last_was_space = false
          i += match[0].length
        elsif chars[i].match?(WHITESPACE_RE)
          unless last_was_space
            out << " "
            out_offsets << offsets[i]
            last_was_space = true
          end
          i += 1
        else
          out << chars[i]
          out_offsets << offsets[i]
          last_was_space = false
          i += 1
        end
      end

      [ out, out_offsets ]
    end

    def decode_entity(match)
      case match[0]
      when "&amp;" then "&"
      when "&lt;" then "<"
      when "&gt;" then ">"
      when "&quot;" then "\""
      else
        codepoint = match[1] ? match[1].to_i : match[2]&.to_i(16)
        codepoint ? [ codepoint ].pack("U") : match[0]
      end
    rescue RangeError
      match[0] # malformed numeric ref (out of Unicode range) — leave as-is
    end

    # -- offset <-> index -------------------------------------------------

    # Nearest stripped-text char index for a raw byte offset. `offsets` is
    # non-decreasing, so this binary-searches for the closest neighbor —
    # covers both "past EOF" (clamps to the last index) and "inside a
    # removed tag span" (picks whichever surviving char is numerically
    # closest in raw bytes).
    def stripped_index_for_offset(offsets, raw_offset)
      lo = 0
      hi = offsets.size
      while lo < hi
        mid = (lo + hi) / 2
        offsets[mid] < raw_offset ? lo = mid + 1 : hi = mid
      end
      return offsets.size - 1 if lo >= offsets.size
      return lo if lo.zero?

      (raw_offset - offsets[lo - 1]) <= (offsets[lo] - raw_offset) ? lo - 1 : lo
    end

    # -- word-boundary trimming --------------------------------------------

    def mid_word?(text, index)
      index.positive? && index < text.length && !text[index - 1].match?(WHITESPACE_RE) && !text[index].match?(WHITESPACE_RE)
    end

    def trim_leading_partial_word(text, from)
      return from unless mid_word?(text, from)

      from += 1 while from < text.length && !text[from - 1].match?(WHITESPACE_RE)
      from
    end

    def trim_trailing_partial_word(text, to)
      return to unless mid_word?(text, to)

      to -= 1 while to.positive? && !text[to - 1].match?(WHITESPACE_RE)
      to
    end

    # -- exact + fuzzy search ----------------------------------------------

    def find_all(text, query)
      occurrences = []
      from = 0
      while (i = text.index(query, from))
        occurrences << i
        from = i + 1
      end
      occurrences
    end

    # Picks the occurrence whose surrounding text best matches the given
    # before/after context (longest matching suffix/prefix). Both sides
    # are compared with whitespace trimmed — callers won't generally
    # preserve the exact single-space seam snippet_at's own output has
    # at the query boundary. With no context, every candidate scores 0
    # and the first occurrence wins.
    def disambiguate(text, query, occurrences, before, after)
      before = before.strip
      after = after.strip
      occurrences.max_by do |index|
        actual_before = text[[ index - before.length - 5, 0 ].max...index].to_s.strip
        actual_after = text[(index + query.length)...(index + query.length + after.length + 5)].to_s.strip
        suffix_overlap(actual_before, before) + prefix_overlap(actual_after, after)
      end
    end

    def suffix_overlap(a, b)
      [ a.length, b.length ].min.downto(1) { |n| return n if a[-n..] == b[-n..] }
      0
    end

    def prefix_overlap(a, b)
      [ a.length, b.length ].min.downto(1) { |n| return n if a[0, n] == b[0, n] }
      0
    end

    def fuzzy_locate(text, offsets, query)
      token = rarest_token(text, query)
      return nil unless token

      token_offset = query.index(token)
      positions = find_all(text, token)
      return nil if positions.empty?

      best_index = nil
      best_similarity = 0.0
      positions.each do |position|
        window_start = [ position - token_offset, 0 ].max
        window = text[window_start, query.length].to_s
        score = similarity(window, query)
        if score > best_similarity
          best_similarity = score
          best_index = window_start
        end
      end

      return nil unless best_index && best_similarity >= FUZZY_THRESHOLD

      offsets[best_index]
    end

    # Rarest (fewest occurrences in text) token of at least FUZZY_MIN_TOKEN
    # chars, falling back to the single longest token when the query has
    # none that long. A token the typo/OCR error landed on has zero
    # literal occurrences — trivially "rarest" but useless as a search
    # anchor, so tokens that actually occur are preferred over ones that
    # don't; only fall through to a non-occurring token if every
    # candidate is absent.
    def rarest_token(text, query)
      words = query.scan(/\S+/)
      tokens = words.select { |word| word.length >= FUZZY_MIN_TOKEN }
      tokens = words.sort_by { |word| -word.length }.first(1) if tokens.empty?
      return nil if tokens.empty?

      present = tokens.select { |token| text.include?(token) }
      (present.presence || tokens).min_by { |token| text.scan(token).size }
    end

    def similarity(a, b)
      max_len = [ a.length, b.length ].max
      return 1.0 if max_len.zero?

      1 - (levenshtein(a, b).to_f / max_len)
    end

    # Bounded by construction: only ever called on fixed, ~snippet-length
    # windows (never the full document), so plain O(n*m) DP is cheap.
    def levenshtein(a, b)
      a_chars = a.chars
      b_chars = b.chars
      previous = (0..b_chars.size).to_a

      a_chars.each_with_index do |a_char, i|
        current = [ i + 1 ]
        b_chars.each_with_index do |b_char, j|
          cost = a_char == b_char ? 0 : 1
          current << [ previous[j + 1] + 1, current[j] + 1, previous[j] + cost ].min
        end
        previous = current
      end

      previous.last
    end
  end
end
