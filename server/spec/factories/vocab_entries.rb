FactoryBot.define do
  factory :vocab_entry do
    user
    book
    sequence(:word) { |n| "word#{n}" }
    lemma { word }
    lang { "en" }
  end
end
