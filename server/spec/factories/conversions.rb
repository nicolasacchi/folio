FactoryBot.define do
  factory :conversion do
    book
    book_file { association :book_file, book: book }
    target_format { "azw3" }
    status { "pending" }
  end
end
