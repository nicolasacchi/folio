FactoryBot.define do
  factory :reading_state do
    book
    device
    sequence(:path) { |n| "#{SecureRandom.hex(4)}/device-#{n}.tar.gz" }
    content_mtime { Time.current }
    size { 64 }
    sequence(:sha256) { |n| Digest::SHA256.hexdigest("reading-state-#{n}") }
  end
end
