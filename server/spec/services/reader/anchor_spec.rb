require "rails_helper"

RSpec.describe Reader::Anchor do
  # A small multi-paragraph MOBI6 text with: HTML entities (&quot; &amp;
  # &#39;), a repeated phrase with divergent continuations (for
  # disambiguation), a multibyte UTF-8 character (café), and two
  # 8+-char-token sentences with typo/smart-quote variants for the
  # fuzzy path.
  let(:sentences) do
    [
      %(It was the best of times, it was the &quot;worst&quot; of times.),
      %(Alice said &amp; smiled at the café by the riverside, near an old oak.),
      %(Later, Alice said &amp; smiled at the café by the seashore, far from that oak.),
      %(It was a wonderful afternoon by the old bridge, quite unlike any other day.),
      %(It&#39;s a lovely afternoon, isn&#39;t it?)
    ]
  end
  let(:raw_html) { "<html><body>\n" + sentences.map { |s| "<p>#{s}</p>\n" }.join + "</body></html>" }
  let(:book_file) { build_mobi_book_file(raw_html) }
  let(:raw) { Library::Mobi.raw_text(book_file.absolute_path) }

  def build_mobi_book_file(text)
    book_file = create(:book_file, format: "mobi", path: "#{SecureRandom.hex(4)}/anchor.mobi")
    MobiFixture.write_with_text(book_file.absolute_path, compression: Library::Mobi::COMPRESSION_NONE,
      text_length: text.b.bytesize, text_records: [ text.b ])
    # Reader::Anchor's disk cache is keyed by book_file.sha256 — the
    # factory's sequence-generated sha256 is deterministic per-process (not
    # tied to the real bytes just written above), so across separate rspec
    # runs it can collide with a stale tmp/cache/reader_anchor entry left by
    # a *different* book from an earlier run, silently serving wrong cached
    # text. Matches the :epub_fixture factory trait's own fix for the same
    # issue.
    book_file.update!(size: File.size(book_file.absolute_path), sha256: Library.sha256(book_file.absolute_path))
    book_file
  end

  describe "offset -> snippet -> locate round trip" do
    it "lands within a few bytes of the original offset" do
      offset = raw.index("Alice said")

      snippet = described_class.snippet_at(book_file, offset)
      expect(snippet[:exact]).to start_with("Alice said & smiled")

      located = described_class.locate(book_file, snippet[:exact], before: snippet[:before], after: snippet[:after])
      expect(located).to be_within(5).of(offset)
    end

    it "decodes entities into the snippet text" do
      offset = raw.index(%(&quot;worst&quot;))
      snippet = described_class.snippet_at(book_file, offset)

      expect(snippet[:exact]).to include(%("worst"))
    end
  end

  describe "EOF and mid-tag offsets" do
    it "clamps an offset past EOF to the end of the text" do
      near_end = described_class.snippet_at(book_file, raw.bytesize - 1)
      way_past = described_class.snippet_at(book_file, raw.bytesize + 10_000)

      expect(way_past).to eq(near_end)
    end

    it "maps an offset landing inside a tag to the nearest following text" do
      tag_start = raw.index("<p>Alice said")
      inside_tag_offset = tag_start + 2 # the '>' byte of "<p>", still inside the tag span

      snippet = described_class.snippet_at(book_file, inside_tag_offset)
      expect(snippet[:exact]).to start_with("Alice")
    end
  end

  describe "multiple-occurrence disambiguation" do
    it "picks the occurrence whose context matches the given after text" do
      first_offset = raw.index("Alice said")
      second_offset = raw.index("Alice said", first_offset + 1)
      expect(second_offset).not_to eq(first_offset)

      query = "Alice said & smiled at the café by the"

      located_first = described_class.locate(book_file, query, after: "riverside")
      located_second = described_class.locate(book_file, query, after: "seashore")

      expect(located_first).to eq(first_offset)
      expect(located_second).to eq(second_offset)
    end
  end

  describe "fuzzy fallback" do
    it "locates a typo'd query via the rarest long token" do
      typo_query = "It was a wonderfull afternoon by teh old brigde, quite unlike any other day."
      # "afternoon" is untouched by the typos and is the query's only 8+-char token
      expected = raw.index("It was a wonderful afternoon")

      # The window is anchored on the token's offset *within the query*, which
      # drifts a little when an earlier word's typo changes its length — a
      # few bytes off is expected for the fuzzy path (unlike the exact path).
      expect(described_class.locate(book_file, typo_query)).to be_within(10).of(expected)
    end

    it "tolerates smart-quote differences" do
      smart_quote_query = "It’s a lovely afternoon, isn’t it?"
      expected = raw.index("It&#39;s a lovely afternoon")

      expect(described_class.locate(book_file, smart_quote_query)).to eq(expected)
    end

    it "returns nil when nothing is close enough" do
      expect(described_class.locate(book_file, "this text does not appear anywhere in the book at all")).to be_nil
    end
  end

  describe "disk cache" do
    it "caches the offset map on disk, keyed by the book_file's sha256, and reuses it" do
      cache_path = described_class.cache_path(book_file.sha256)
      FileUtils.rm_f(cache_path)

      expect(Library::Mobi).to receive(:raw_text).once.and_call_original

      2.times { described_class.snippet_at(book_file, 0) }

      expect(File).to exist(cache_path)
    end
  end
end
