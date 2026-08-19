module ReaderHelper
  # Label for the reader top bar's current-variant stamp — see
  # ReaderController#show's @variant. "none" (no OCR companion, no text
  # companion — nothing to distinguish) never gets a stamp.
  def reader_variant_stamp_label(variant)
    case variant
    when "ocr" then "text layer"
    when "raw" then "original scan"
    when "text" then "text only"
    end
  end

  # { label:, url:, title: } for every OTHER variant this book/file
  # combination actually offers, given the reader's current @variant —
  # empty when there's nothing to switch to (a plain file with neither an
  # OCR nor a text companion). "ocr"/"none" both resolve to the plain
  # default URL (read_book_path with no params); ocr_fresh? alone decides
  # whether that default is actually the OCR text layer or just the raw
  # file, which is also what decides the label a switch back to it gets.
  def reader_variant_switches(book, file, variant)
    ocr_present = file.ocr_fresh?
    text_present = file.text_fresh?
    current = %w[raw text].include?(variant) ? variant : "default"
    available = [ "default" ] + (ocr_present ? [ "raw" ] : []) + (text_present ? [ "text" ] : [])

    (available - [ current ]).map do |target|
      case target
      when "raw"
        { label: "original scan", url: read_book_path(book, raw: 1),
          title: "Switch to the original scan" }
      when "text"
        { label: "text only", url: read_book_path(book, text: 1),
          title: "Switch to the plain-text reflow version" }
      else
        { label: ocr_present ? "text layer" : "original file", url: read_book_path(book),
          title: ocr_present ? "Switch to the OCR text-layer version" : "Switch to the original file" }
      end
    end
  end
end
