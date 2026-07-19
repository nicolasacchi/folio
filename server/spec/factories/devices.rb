FactoryBot.define do
  factory :device do
    sequence(:name) { |n| "kindle-#{n}" }
    kind { "kindle" }

    # A deterministic raw token (not the random one .assign_token would
    # generate) so request specs can authenticate as this device via
    # X-Api-Token without ever having stored plaintext — only its digest
    # goes to the DB, exactly like a real device (see Device#raw_token).
    transient do
      sequence(:raw_token) { |n| "testtoken#{n}" }
    end

    after(:build) do |device, evaluator|
      device.raw_token = evaluator.raw_token
      device.token_digest = Device.digest_token(evaluator.raw_token)
    end
  end
end
