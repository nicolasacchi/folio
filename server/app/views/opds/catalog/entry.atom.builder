# The single-entry document (OPDS 1.2 §2.2 "type=entry"): the document's
# root element IS <entry>, not <feed> — see _entry.atom.builder's
# `standalone:` handling for the namespace declarations that requires.
xml.instruct!
xml << render(partial: "opds/catalog/entry", locals: { book: @book, standalone: true })
