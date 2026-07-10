require 'rails_helper'

RSpec.describe Library::DuplicateGroups do
  it "groups books by normalized title and author" do
    a = create(:book, title: "Dune", author: "Frank Herbert")
    b = create(:book, title: "  dune ", author: "FRANK  HERBERT")
    create(:book, title: "Dune Messiah", author: "Frank Herbert")

    groups = described_class.tuples

    expect(groups.size).to eq(1)
    expect(groups.first.map(&:first)).to contain_exactly(a.id, b.id)
  end

  it "picks the edition with the most formats as merge target, then cover, then age" do
    old_single = create(:book, title: "Dune", author: "F. H.", created_at: 2.days.ago)
    create(:book_file, book: old_single, format: "epub")
    rich = create(:book, title: "Dune", author: "F. H.", created_at: 1.day.ago)
    create(:book_file, book: rich, format: "epub", path: "#{SecureRandom.hex(4)}/d.epub")
    create(:book_file, book: rich, format: "azw3", path: "#{SecureRandom.hex(4)}/d.azw3")

    books = Book.includes(:book_files).where(id: [ old_single.id, rich.id ]).to_a
    expect(described_class.merge_target(books)).to eq(rich)
  end
end
