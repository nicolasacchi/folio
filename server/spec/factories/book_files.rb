FactoryBot.define do
  factory :book_file do
    book
    format { "epub" }
    sequence(:path) { |n| "#{SecureRandom.hex(4)}/file-#{n}.epub" }
    size { 1234 }
    sequence(:sha256) { |n| Digest::SHA256.hexdigest("book-file-#{n}") }
    source { "upload" }

    # Materializes a real file at the record's library path.
    trait :on_disk do
      after(:create) do |book_file|
        FileUtils.mkdir_p(book_file.absolute_path.dirname)
        File.write(book_file.absolute_path, "content of #{book_file.path}")
      end
    end

    # A real, tiny, valid EPUB — for specs that actually open/stream the
    # file rather than just exercising the DB row (see EpubFixture).
    trait :epub_fixture do
      format { "epub" }
      after(:create) do |book_file|
        EpubFixture.write(book_file.absolute_path)
        book_file.update!(size: File.size(book_file.absolute_path), sha256: Library.sha256(book_file.absolute_path))
      end
    end
  end
end
