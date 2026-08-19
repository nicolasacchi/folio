require "rails_helper"

RSpec.describe KindleWritebackJob do
  let(:book) { create(:book) }
  let(:user) { create(:user) }

  # A real azw3 book_file with the given plain-text body, so
  # Reader::Anchor can actually locate `exact` snippets against it.
  def azw3_with_text(text)
    azw3 = create(:book_file, book: book, format: "azw3", path: "#{SecureRandom.hex(4)}/wb.azw3")
    MobiFixture.write_with_text(azw3.absolute_path, compression: Library::Mobi::COMPRESSION_NONE,
      text_length: text.b.bytesize, text_records: [ text.b ])
    # Content-address the cache key on the real bytes just written — the
    # factory's default sha256 is an arbitrary sequence value that could
    # collide with another spec's cached Reader::Anchor entry.
    azw3.update!(sha256: Library.sha256(azw3.absolute_path), size: File.size(azw3.absolute_path))
    azw3
  end

  it "locates the saved anchor in the book's text and calls Reader::KindleWriteback with the resolved offset" do
    marker = "the quick marker sentence for locate"
    text = ("a" * 500) + marker + ("b" * 500)
    azw3_with_text(text)
    create(:reader_position, book: book, user: user, context: { "exact" => marker, "before" => "", "after" => "" })

    allow(Reader::KindleWriteback).to receive(:call)
      .and_return(Reader::KindleWriteback::Result.new(written: true, reason: nil))

    described_class.perform_now(book.id, user.id)

    expected_offset = text.index(marker)
    expect(Reader::KindleWriteback).to have_received(:call).with(hash_including(book: book, offset: expected_offset))
  end

  it "does nothing when the reader position is gone" do
    expect(Reader::KindleWriteback).not_to receive(:call)

    expect { described_class.perform_now(book.id, user.id) }.not_to raise_error
  end

  it "ignores a 'text' variant position — only the shared (variant: '') row anchors into the physical Kindle" do
    marker = "a marker that only the text-variant position has"
    azw3_with_text(("a" * 200) + marker + ("b" * 200))
    create(:reader_position, book: book, user: user, variant: "text", context: { "exact" => marker })

    expect(Reader::KindleWriteback).not_to receive(:call)
    described_class.perform_now(book.id, user.id)
  end

  it "does nothing when the saved context has no exact anchor" do
    create(:reader_position, book: book, user: user, context: {})

    expect(Reader::KindleWriteback).not_to receive(:call)
    described_class.perform_now(book.id, user.id)
  end

  it "bails without writing when the anchor can't be located in the book's text" do
    azw3_with_text("some completely different filler text " * 20)
    create(:reader_position, book: book, user: user, context: { "exact" => "text that never appears anywhere" })

    expect(Reader::KindleWriteback).not_to receive(:call)
    described_class.perform_now(book.id, user.id)
  end

  it "skips the write when the web device's own last position already matches the resolved offset" do
    marker = "already synced marker text"
    text = ("a" * 200) + marker + ("b" * 200)
    azw3_with_text(text)
    offset = text.index(marker)
    create(:reader_position, book: book, user: user, context: { "exact" => marker })
    create(:reading_state, book: book, device: Device.web_reader!, last_position: offset)

    expect(Reader::KindleWriteback).not_to receive(:call)
    described_class.perform_now(book.id, user.id)
  end

  it "retries once against a fresh basis state when the first write reports :stale" do
    marker = "retry marker text here"
    text = ("a" * 200) + marker + ("b" * 200)
    azw3_with_text(text)
    create(:reader_position, book: book, user: user, context: { "exact" => marker })

    stale = Reader::KindleWriteback::Result.new(written: false, reason: :stale)
    success = Reader::KindleWriteback::Result.new(written: true, reason: nil)
    allow(Reader::KindleWriteback).to receive(:call).and_return(stale, success)

    described_class.perform_now(book.id, user.id)

    expect(Reader::KindleWriteback).to have_received(:call).twice
  end

  it "discards without raising when the book has since been deleted" do
    book_id = book.id
    book.destroy!

    expect { described_class.perform_now(book_id, user.id) }.not_to raise_error
  end

  describe "end-to-end against a real physical bundle" do
    let(:mbs) { File.binread(Rails.root.join("spec/fixtures/sidecars/krds.mbs")) }
    let(:kindle) { create(:device, kind: "kindle", reader_writeback: true) }

    def sync_bundle(content_mtime:)
      tar_io = StringIO.new
      Gem::Package::TarWriter.new(tar_io) do |tar|
        tar.add_file_simple("Book.sdr/Book.mbs", 0o644, mbs.bytesize) { |io| io.write(mbs) }
      end
      gz_io = StringIO.new
      gz = Zlib::GzipWriter.new(gz_io)
      gz.write(tar_io.string)
      gz.close
      bytes = gz_io.string

      path = Library.reading_state_path(book, kindle)
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, bytes)

      create(:reading_state, book: book, device: kindle,
        path: path.relative_path_from(Library.reading_states_root).to_s,
        content_mtime: content_mtime, size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes))
    end

    it "rewrites the physical bundle's KRDS position via the real service" do
      sync_bundle(content_mtime: 1.hour.ago)
      marker = "a brand new reading position"
      text = ("a" * 5_000) + marker + ("b" * 5_000)
      azw3_with_text(text)
      offset = text.index(marker)
      create(:reader_position, book: book, user: user, context: { "exact" => marker })

      described_class.perform_now(book.id, user.id)

      web_state = book.reading_states.find_by(device: Device.web_reader!)
      expect(web_state).to be_present

      members = {}
      Zlib::GzipReader.open(web_state.absolute_path.to_s) do |gz|
        Gem::Package::TarReader.new(gz) { |tar| tar.each { |e| members[e.full_name] = e.read.to_s.b if e.file? } }
      end
      rewritten = Library::Krds.parse(members["Book.sdr/Book.mbs"])
      expect(rewritten.objects.find { |o| o.name == "fpr" }.children[0].value).to eq(offset.to_s)
    end
  end
end
