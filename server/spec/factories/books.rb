FactoryBot.define do
  factory :book do
    sequence(:title) { |n| "Book Title #{n}" }
    author { "Test Author" }
  end
end
