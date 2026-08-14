require 'rails_helper'

RSpec.describe Library::StorageGc do
  # Stubbed so this spec never touches the real (shared, suite-wide)
  # LIBRARY_ROOT test storage directory.
  let(:root) { Pathname.new(Dir.mktmpdir("storage-gc-spec")) }

  before { allow(Library).to receive(:base_root).and_return(root) }
  after { FileUtils.rm_rf(root) }

  def write(path, mtime:)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "x" * 10)
    File.utime(mtime.to_time, mtime.to_time, path)
  end

  it "keeps DB-referenced files, deletes old orphans, and spares fresh orphans" do
    book = create(:book)
    create(:book_file, book: book, prepared_path: "prepared/#{book.public_id}.mobi")

    referenced_prepared = root.join("prepared", "#{book.public_id}.mobi")
    referenced_cover = root.join("covers", "#{book.public_id}.jpg")
    old_orphan = root.join("prepared", "staging-orphan.mobi")
    fresh_orphan = root.join("thumbnails", "fresh-orphan.jpg")

    write(referenced_prepared, mtime: 7.hours.ago)
    write(referenced_cover, mtime: 7.hours.ago)
    write(old_orphan, mtime: 7.hours.ago)
    write(fresh_orphan, mtime: 1.hour.ago)

    stats = described_class.sweep!

    expect(File.exist?(referenced_prepared)).to be(true)
    expect(File.exist?(referenced_cover)).to be(true)
    expect(File.exist?(old_orphan)).to be(false)
    expect(File.exist?(fresh_orphan)).to be(true)

    expect(stats.removed).to eq(1)
    expect(stats.bytes_reclaimed).to eq(10)
  end

  it "treats ocr_path exactly like prepared_path: keeps referenced companions, sweeps orphans" do
    book = create(:book)
    create(:book_file, book: book, format: "pdf", ocr_path: "ocr/#{book.public_id}.ocr.pdf")

    referenced_ocr = root.join("ocr", "#{book.public_id}.ocr.pdf")
    old_ocr_orphan = root.join("ocr", "staging-orphan.ocr.pdf")

    write(referenced_ocr, mtime: 7.hours.ago)
    write(old_ocr_orphan, mtime: 7.hours.ago)

    stats = described_class.sweep!

    expect(File.exist?(referenced_ocr)).to be(true)
    expect(File.exist?(old_ocr_orphan)).to be(false)
    expect(stats.removed).to eq(1)
  end

  it "never touches directories outside the swept set" do
    untouched = root.join("library", "some-book", "original.epub")
    write(untouched, mtime: 7.hours.ago)

    described_class.sweep!

    expect(File.exist?(untouched)).to be(true)
  end

  it "returns zero stats when nothing is on disk" do
    stats = described_class.sweep!

    expect(stats.removed).to eq(0)
    expect(stats.bytes_reclaimed).to eq(0)
  end
end
