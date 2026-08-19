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

    # A text-companion build is also pdf-sourced (see TextCompanionJob) —
    # target_format "txt" names the primary artifact (the reader-facing
    # companion), mirroring :ocr's convention.
    trait :text do
      kind { "text" }
      book_file { association :book_file, book: book, format: "pdf" }
      target_format { "txt" }
    end
  end
end
