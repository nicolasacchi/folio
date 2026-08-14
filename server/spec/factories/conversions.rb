FactoryBot.define do
  factory :conversion do
    book
    book_file { association :book_file, book: book }
    target_format { "azw3" }
    status { "pending" }

    # An OCR run is pdf -> pdf, so both the source file and the target
    # format need to line up on "pdf" (see Conversion#target_differs_from_source).
    trait :ocr do
      kind { "ocr" }
      book_file { association :book_file, book: book, format: "pdf" }
      target_format { "pdf" }
    end
  end
end
