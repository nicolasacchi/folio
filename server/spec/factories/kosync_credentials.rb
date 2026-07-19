FactoryBot.define do
  factory :kosync_credential do
    sequence(:username) { |n| "kosync-user-#{n}" }
    key { "5f4dcc3b5aa765d61d8327deb882cf99" } # md5("password"), like a real client would send
  end
end
