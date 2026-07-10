FactoryBot.define do
  factory :device do
    sequence(:name) { |n| "kindle-#{n}" }
  end
end
