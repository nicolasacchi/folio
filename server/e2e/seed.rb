# Seeds the data the Playwright e2e suite drives (see reader.spec.js).
# Runs against the isolated e2e database and library root that boot.sh sets
# up via DATABASE_URL / LIBRARY_ROOT, so the RSpec test database is never
# touched. Idempotent: wipes and recreates its own rows on every boot.
require "json"
require_relative "fxl_epub"
require_relative "../spec/support/epub_fixture"

user = User.find_or_initialize_by(email_address: "e2e@example.com")
user.password = "e2e-password"
user.save!

Book.where(title: [ "E2E Fixed-Layout Book", "E2E Reflowable Book" ]).find_each(&:destroy!)

def materialize(book, filename)
  file = book.book_files.create!(
    format: "epub", path: "e2e/#{filename}",
    size: 0, sha256: "pending-#{filename}", source: "upload"
  )
  yield file.absolute_path
  file.update!(size: File.size(file.absolute_path), sha256: Library.sha256(file.absolute_path))
  file
end

fxl = Book.create!(title: "E2E Fixed-Layout Book", author: "E2E")
materialize(fxl, "fxl.epub") { |path| FxlEpub.write(path) }

reflowable = Book.create!(title: "E2E Reflowable Book", author: "E2E")
materialize(reflowable, "reflowable.epub") { |path| EpubFixture.write(path) }

# The Playwright suite reads the seeded IDs from here (written on every boot,
# gitignored) rather than hardcoding IDs that change across reseeds.
File.write(
  Rails.root.join("e2e/.seed.json"),
  JSON.pretty_generate({ fxlId: fxl.id, reflowableId: reflowable.id })
)

puts "[e2e] seeded user e2e@example.com, fxl book ##{fxl.id}, reflowable book ##{reflowable.id}"
