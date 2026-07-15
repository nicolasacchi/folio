FactoryBot.define do
  factory :annotation do
    book
    device
    kind { "highlight" }
    source { "clippings" }
    raw_title { book&.title || "Untitled" }
    sequence(:fingerprint) { |n| Digest::SHA256.hexdigest("annotation-#{n}") }
    added_at { Time.current }
    content { "Highlighted passage." }
  end
end
