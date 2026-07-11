FactoryBot.define do
  factory :delivery do
    book
    device

    trait :delivered do
      delivered_at { Time.current }
    end
  end
end
