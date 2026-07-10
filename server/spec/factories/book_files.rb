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
  end
end
