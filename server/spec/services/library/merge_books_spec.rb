require 'rails_helper'

RSpec.describe Library::MergeBooks do
  it "moves non-conflicting formats over and destroys the emptied source" do
    target = create(:book, title: "Dune")
    source = create(:book, title: "Dune")
    create(:book_file, :on_disk, book: target, format: "epub")
    moving = create(:book_file, :on_disk, book: source, format: "azw3", path: "#{SecureRandom.hex(4)}/dune.azw3")

    merged = described_class.call(source, target)

    expect(merged).to eq(%w[azw3])
    expect(target.reload.formats).to contain_exactly("epub", "azw3")
    expect(Book.exists?(source.id)).to be(false)
    expect(File).to exist(moving.reload.absolute_path)
    expect(moving.book_id).to eq(target.id)
  end

  it "keeps the source book when a conflicting managed file cannot move" do
    target = create(:book, title: "Dune")
    source = create(:book, title: "Dune")
    create(:book_file, :on_disk, book: target, format: "epub")
    create(:book_file, :on_disk, book: source, format: "epub", path: "#{SecureRandom.hex(4)}/dune-2.epub")

    described_class.call(source, target)

    expect(Book.exists?(source.id)).to be(true)
    expect(source.reload.formats).to eq(%w[epub])
  end

  it "drops a conflicting external reference without touching the source file" do
    target = create(:book, title: "Dune")
    source = create(:book, title: "Dune")
    create(:book_file, :on_disk, book: target, format: "epub")
    external = Rails.root.join("tmp", "external-dune-dupe.epub")
    File.write(external, "different epub bytes")
    create(:book_file, book: source, format: "epub", path: external.to_s, source: "scan")

    described_class.call(source, target)

    expect(Book.exists?(source.id)).to be(false) # emptied and removed
    expect(File).to exist(external)              # scan-root file untouched
  ensure
    FileUtils.rm_f(external)
  end

  it "re-points external files without touching the disk" do
    target = create(:book, title: "Dune")
    source = create(:book, title: "Dune")
    external = Rails.root.join("tmp", "external-dune.mobi")
    File.write(external, "mobi bytes")
    file = create(:book_file, book: source, format: "mobi", path: external.to_s, source: "scan")

    described_class.call(source, target)

    expect(file.reload.book_id).to eq(target.id)
    expect(file.path).to eq(external.to_s)
    expect(File).to exist(external)
  ensure
    FileUtils.rm_f(external)
  end
end
