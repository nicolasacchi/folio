// Not part of upstream foliate-js — see VERSION. A minimal adapter for
// plain .txt files, modeled on fb2.js (the simplest upstream adapter):
// same Book interface contract (metadata/getCover/sections/toc/
// resolveHref/splitTOCHref/getTOCFragment/isExternal/destroy), same
// document+object-URL section pattern, but with none of fb2.js's markup
// conversion — a bare .txt file has no chapters, TOC, or cover to extract.

const MIME = {
    XHTML: 'application/xhtml+xml',
}

// Collapses all runs of whitespace (including embedded hard-wrapped line
// breaks *within* a paragraph) to single spaces and trims the ends — same
// spirit as fb2.js's normalizeWhitespace, applied per-paragraph here.
// Blank-line paragraph splits happen before this runs (see makeTXT), so
// this never merges two separate paragraphs into one.
const normalizeWhitespace = str => str.replace(/\s+/g, ' ').trim()

const style = URL.createObjectURL(new Blob([`
p {
    margin: 0 0 1em;
}
`], { type: 'text/css' }))

const template = body => `<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
    <head><link href="${style}" rel="stylesheet" type="text/css"/></head>
    <body>${body}</body>
</html>`

export const makeTXT = async file => {
    const book = {}

    // `TextDecoder('utf-8')` defaults to `fatal: false`, so invalid byte
    // sequences decode to U+FFFD replacement characters instead of
    // throwing — good enough for a best-effort plain-text render.
    const buffer = await file.arrayBuffer()
    const text = new TextDecoder('utf-8').decode(buffer)

    // Split into paragraphs on one-or-more blank lines; everything inside
    // a paragraph then gets its internal whitespace normalized.
    const paragraphs = text
        .split(/\r\n|\r/g).join('\n')
        .split(/\n[ \t]*\n+/)
        .map(normalizeWhitespace)
        .filter(Boolean)

    const doc = document.implementation.createDocument(
        'http://www.w3.org/1999/xhtml', 'html')
    const body = doc.createElement('body')
    for (const paragraph of paragraphs) {
        const p = doc.createElement('p')
        // `.textContent`, never innerHTML with raw text — book content is
        // untrusted, and this is the only thing standing between it and
        // getting parsed as markup.
        p.textContent = paragraph
        body.append(p)
    }

    const str = template(body.innerHTML)
    const blob = new Blob([str], { type: MIME.XHTML })
    const url = URL.createObjectURL(blob)

    // No extractable metadata from a bare .txt file — the reader chrome
    // already shows the book's real title from server-side data, not
    // from the book object itself.
    book.metadata = { title: null, language: null }
    book.getCover = () => null

    book.sections = [{
        id: 0,
        load: () => url,
        createDocument: () => new DOMParser().parseFromString(str, MIME.XHTML),
        size: blob.size,
    }]

    // No chapters to navigate to and nothing to link — a single
    // unstructured section has neither.
    book.toc = []
    book.resolveHref = () => undefined
    book.splitTOCHref = () => []
    book.getTOCFragment = () => null
    book.isExternal = () => false

    book.destroy = () => URL.revokeObjectURL(url)
    return book
}
