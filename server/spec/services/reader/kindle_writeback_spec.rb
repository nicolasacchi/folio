require "rails_helper"

RSpec.describe Reader::KindleWriteback do
  # Real device captures — see app/services/library/krds.rb's header
  # comment for the byte layout. mbs carries rewritable lpr/fpr
  # positions; mbp1 only has sync_lpr (boolean-only, not rewritable).
  let(:mbs) { File.binread(Rails.root.join("spec/fixtures/sidecars/krds.mbs")) }
  let(:mbp1) { File.binread(Rails.root.join("spec/fixtures/sidecars/krds.mbp1")) }
  let(:book) { create(:book) }
  let(:kindle) { create(:device, kind: "kindle", reader_writeback: true) }

  # tar.gz's the given { member_name => bytes } into a real bundle at
  # kindle's reading_state path and creates the matching ReadingState row.
  def sync_bundle(members, content_mtime: 1.hour.ago)
    tar_io = StringIO.new
    Gem::Package::TarWriter.new(tar_io) do |tar|
      members.each { |name, bytes| tar.add_file_simple(name, 0o644, bytes.bytesize) { |io| io.write(bytes) } }
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

  describe ".latest_physical_state" do
    let!(:other) { create(:device, kind: "kindle", name: "other-kindle") }
    let!(:user) { create(:user) }

    it "prefers the acting user's preferred device when it has a state" do
      create(:reading_state, book: book, device: other, content_mtime: 1.hour.ago, progress_percent: 10)
      preferred_state = create(:reading_state, book: book, device: kindle, content_mtime: 1.day.ago, progress_percent: 40)
      user.update!(preferred_device: kindle)

      expect(described_class.latest_physical_state(book, user: user)).to eq(preferred_state)
    end

    it "falls back to newest content_mtime without a preferred match" do
      older = create(:reading_state, book: book, device: kindle, content_mtime: 2.days.ago, progress_percent: 10)
      newer = create(:reading_state, book: book, device: other, content_mtime: 1.hour.ago, progress_percent: 20)

      expect(described_class.latest_physical_state(book, user: user)).to eq(newer)
      expect(described_class.latest_physical_state(book)).to eq(newer)
      expect(described_class.latest_physical_state(book, user: user)).not_to eq(older)
    end
  end

  describe "the reader_writeback flag" do
    it "short-circuits when no physical device has opted in" do
      kindle.update!(reader_writeback: false)
      sync_bundle({ "Book.sdr/Book.mbs" => mbs })

      result = described_class.call(book: book, offset: 12_345)

      expect(result.written).to be false
      expect(result.reason).to eq(:writeback_disabled)
    end

    it "short-circuits when the opted-in device isn't physical (a web-kind row doesn't count)" do
      kindle.update!(reader_writeback: false)
      create(:device, kind: "web", reader_writeback: true, name: "not-actually-physical")
      sync_bundle({ "Book.sdr/Book.mbs" => mbs })

      result = described_class.call(book: book, offset: 12_345)

      expect(result.written).to be false
      expect(result.reason).to eq(:writeback_disabled)
    end
  end

  describe "no physical reading state to derive a bundle from" do
    it "returns :no_reading_state when the book has never synced from a physical device" do
      kindle # ensure the opted-in device exists

      result = described_class.call(book: book, offset: 12_345)

      expect(result.written).to be false
      expect(result.reason).to eq(:no_reading_state)
    end
  end

  describe "staleness" do
    it "returns :stale when the basis is older than the latest physical state" do
      sync_bundle({ "Book.sdr/Book.mbs" => mbs }, content_mtime: Time.current)
      basis = build_stubbed(:reading_state, content_mtime: 1.day.ago)

      result = described_class.call(book: book, offset: 12_345, basis_state: basis)

      expect(result.written).to be false
      expect(result.reason).to eq(:stale)
      expect(book.reading_states.find_by(device: Device.web_reader!)).to be_nil # nothing was written
    end

    it "proceeds when the basis matches the latest state's mtime" do
      mtime = Time.zone.at(1_700_000_000)
      sync_bundle({ "Book.sdr/Book.mbs" => mbs }, content_mtime: mtime)
      basis = build_stubbed(:reading_state, content_mtime: mtime)

      result = described_class.call(book: book, offset: 12_345, basis_state: basis)

      expect(result.written).to be true
    end
  end

  describe "member size cap" do
    it "rejects the whole write-back when a bundle member exceeds MAX_MEMBER_BYTES" do
      oversized = "x".b * (described_class::MAX_MEMBER_BYTES + 1)
      sync_bundle({ "Book.sdr/Book.mbs" => mbs, "Book.sdr/huge.bin" => oversized })

      result = described_class.call(book: book, offset: 12_345)

      expect(result.written).to be false
      expect(result.reason).to eq(:oversized_member)
      expect(book.reading_states.find_by(device: Device.web_reader!)).to be_nil # nothing was written
    end
  end

  describe "no rewritable position objects" do
    it "returns :no_position_objects when the only KRDS member has no rewritable position" do
      sync_bundle({ "Book.sdr/Book.mbp1" => mbp1 })

      result = described_class.call(book: book, offset: 12_345)

      expect(result.written).to be false
      expect(result.reason).to eq(:no_position_objects)
    end
  end

  describe "a successful write-back" do
    it "rewrites the position, preserves other members byte-identically, and syncs a new web ReadingState" do
      other_member = "cover thumbnail bytes, not KRDS".b
      sync_bundle({ "Book.sdr/Book.mbs" => mbs, "Book.sdr/Book.mbp1" => mbp1, "Book.sdr/thumb.jpg" => other_member })

      result = described_class.call(book: book, offset: 99_999)
      expect(result.written).to be true
      expect(result.reason).to be_nil

      web_state = book.reading_states.find_by(device: Device.web_reader!)
      expect(web_state).to be_present
      expect(web_state.content_mtime).to be > kindle.reading_states.find_by(book: book).content_mtime

      members = {}
      Zlib::GzipReader.open(web_state.absolute_path.to_s) do |gz|
        Gem::Package::TarReader.new(gz) { |tar| tar.each { |e| members[e.full_name] = e.read.to_s.b if e.file? } }
      end

      expect(members.keys).to eq(%w[Book.sdr/Book.mbs Book.sdr/Book.mbp1 Book.sdr/thumb.jpg])
      expect(members["Book.sdr/thumb.jpg"]).to eq(other_member)
      expect(members["Book.sdr/Book.mbp1"]).to eq(mbp1) # KRDS but no rewritable position -> untouched

      rewritten_mbs = Library::Krds.parse(members["Book.sdr/Book.mbs"])
      expect(rewritten_mbs.objects.find { |o| o.name == "fpr" }.children[0].value).to eq("99999")

      expect(web_state.sha256).to eq(Digest::SHA256.hexdigest(File.binread(web_state.absolute_path)))
      expect(web_state.size).to eq(File.size(web_state.absolute_path))
    end

    it "enqueues ParseSidecarJob for the new web ReadingState row" do
      sync_bundle({ "Book.sdr/Book.mbs" => mbs })

      expect {
        described_class.call(book: book, offset: 42)
      }.to have_enqueued_job(ParseSidecarJob)
    end

    it "clamps the new content_mtime past the latest state's when the clock hasn't moved forward" do
      future_mtime = 1.year.from_now
      sync_bundle({ "Book.sdr/Book.mbs" => mbs }, content_mtime: future_mtime)

      result = described_class.call(book: book, offset: 42)

      expect(result.written).to be true
      web_state = book.reading_states.find_by(device: Device.web_reader!)
      expect(web_state.content_mtime).to be > future_mtime
    end
  end
end
