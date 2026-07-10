require 'rails_helper'

RSpec.describe CatalogOperationJob do
  it "queues Kindle conversions only for books without a deliverable file" do
    epub_only = create(:book)
    create(:book_file, book: epub_only, format: "epub")
    deliverable = create(:book)
    create(:book_file, book: deliverable, format: "azw3", path: "#{SecureRandom.hex(4)}/x.azw3")

    expect { described_class.perform_now("convert_all") }
      .to have_enqueued_job(EnsureKindleFormatJob).with(epub_only.id).exactly(:once)
  end

  it "merges every duplicate group into its best edition" do
    target = create(:book, title: "Dune", author: "F. H.")
    create(:book_file, :on_disk, book: target, format: "epub")
    create(:book_file, :on_disk, book: target, format: "azw3", path: "#{SecureRandom.hex(4)}/d.azw3")
    extra = create(:book, title: "Dune", author: "F. H.")
    create(:book_file, :on_disk, book: extra, format: "mobi", path: "#{SecureRandom.hex(4)}/d.mobi")

    described_class.perform_now("merge_duplicates")

    expect(Book.exists?(extra.id)).to be(false)
    expect(target.reload.formats).to contain_exactly("epub", "azw3", "mobi")
  end
end
