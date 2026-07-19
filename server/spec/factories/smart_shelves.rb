FactoryBot.define do
  factory :smart_shelf do
    sequence(:name) { |n| "Smart shelf #{n}" }
    rules { { "match" => "all", "conditions" => [] } }
  end
end
