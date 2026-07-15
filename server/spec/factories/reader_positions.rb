FactoryBot.define do
  factory :reader_position do
    book
    user
    cfi { "epubcfi(/6/4!/4/2/1:0)" }
    fraction { 0.0 }
    percent { 0.0 }
  end
end
