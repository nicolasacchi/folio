module BooksHelper
  # Stable hue for a book's generated cover, derived from its public id.
  def cover_hue(book)
    book.public_id.to_i(16) % 360
  end

  def conversion_stamp_class(conversion)
    case conversion.status
    when "completed" then "stamp stamp--ready"
    when "failed" then "stamp stamp--failed"
    else "stamp stamp--pending"
    end
  end

  def format_size(bytes)
    number_to_human_size(bytes, precision: 2)
  end

  # Per-device switch link "back to normal" label — used once a delivery
  # is on the "text" variant (see Delivery::VARIANTS) and there's no fresh
  # OCR companion to name it after (DeliveriesController's own
  # #variant_label always says "text layer" there, but that word is
  # misleading with nothing to actually layer onto).
  def auto_variant_label(ocr_original)
    ocr_original ? "text layer" : "original file"
  end

  # Screen-reader announcement for the search mode toggle (books/index) —
  # the visual state is just a bolded word, so this spells out what each
  # mode actually does for the aria-live region next to it.
  def search_mode_announcement(mode)
    case mode
    when "full" then "Searching full text: descriptions and text extracted from your books, in addition to titles and authors."
    when "semantic" then "Searching by meaning, blending full-text relevance with the semantic index."
    else "Searching titles, authors, and series."
    end
  end

  # Chip/breadcrumb label for a books.category value, including the two
  # values that aren't real taxonomy categories.
  def category_label(value)
    case value
    when BooksController::UNCATEGORIZED then "Uncategorized"
    when "_inbox" then "Inbox"
    else Library::Taxonomy.label_for(value)
    end
  end

  # <optgroup>-per-root select options for the edit form: taxonomy roots
  # and their subs, plus Inbox, plus (if the book's current value isn't
  # in the taxonomy — a renamed dir, a pre-taxonomy-bump edit) the raw
  # current value so saving the form again can't silently drop it.
  def category_select_options(current)
    groups = Library::Taxonomy.categories.keys.map do |root|
      options = [ [ Library::Taxonomy.label_for(root), root ] ] +
        Library::Taxonomy.subs_for(root).keys.map { |sub| [ Library::Taxonomy.sub_label_for(root, sub), "#{root}/#{sub}" ] }
      [ Library::Taxonomy.label_for(root), options ]
    end
    groups << [ "Other", [ [ "Inbox", "_inbox" ] ] ]

    if current.present? && !Library::Taxonomy.known?(current) && current != "_inbox"
      groups.unshift([ "Current (not in the taxonomy)", [ [ current, current ] ] ])
    end

    grouped_options_for_select(groups, current)
  end
end
