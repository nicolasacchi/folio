# Web Reader — implementation plan (2026-07-14)

> STATUS 2026-07-14 eve: IMPLEMENTED (phases 1–4 all done, uncommitted at time
> of writing). 325 rspec + 21 cargo tests green; 16 review findings triaged, 14
> confirmed and fixed (incl. reader-scoped CSP, physical-device controller
> scoping, KRDS depth/size hardening); live Playwright E2E passed incl. the
> full two-way loop (KRDS bundle position rewritten and applied to the web
> device row). Residual known gaps: web highlights are not written back into
> the Kindle's KRDS annotation cache (v2), no offline/PWA book cache, book
> content iframe is same-origin (CSP nonce mitigates scripts; full origin
> isolation would need a separate host), solid_queue worker path for
> KindleWritebackJob proven via perform_now only. The MOBI6-vs-KF8 position
> unit hypothesis still wants a one-off live-device check before enabling
> devices.reader_writeback on the real Kindle.

In-browser ebook reader inside Folio with Kindle parity: full-screen reading,
notes & highlights, word lookup, mobile-first navigation, and **two-way
reading-position sync with the physical Kindle**.

Decisions (agreed):
- Full two-way position sync in v1 (server rewrites `lpr`/`fpr` in a copy of the
  latest physical sidecar bundle; the Kindle applies it via the existing
  latest-mtime-wins pipeline). Safeguards: per-device opt-in flag
  (`devices.reader_writeback`, default off), backward jumps need explicit
  confirmation, device-side `.bak` backups already exist.
- Reader renders the best available format: EPUB preferred, AZW3/MOBI natively
  (foliate-js parses them), converting to EPUB on demand when nothing renderable
  exists (reuses the existing Conversion pipeline).
- Word lookup: offline kaikki.org (Wiktionary) EN+IT SQLite dictionary, built by
  `script/build_dictionary.rb`; Wikipedia summary card opt-in (external call).

Engine: **foliate-js** (MIT, zero deps, ES modules — fits importmap; paginated +
scrolled flows, touch nav, SVG highlight overlays, CFI, footnotes, search,
native MOBI/KF8). Vendored snapshot under `public/reader/foliate-js-<sha>/`
(served unfingerprinted so its internal relative imports work; cache-busted by
the commit-hash dir name), entry modules pinned in the importmap.

Position mapping web↔Kindle is **text-anchor based** (never offset arithmetic
across formats): the server extracts the MOBI6 text stream (PalmDoc decompress
in Ruby — Calibre never writes HUFF/CDIC), maps KRDS offset → snippet → the
client locates it via foliate-js search → CFI, and the reverse for write-back.
Working hypothesis (supported by existing `progress_percent` math): KRDS
positions on this firmware index the MOBI6 stream of the joint file. To be
re-verified live on the device; the mapping layer is unit-agnostic.

## Architecture

- `GET  /books/:id/read`               ReaderController#show — chrome-less `reader` layout
- `GET  /books/:id/read/file`          streams best format, real MIME, inline
- `PUT  /books/:id/read/position`      {cfi, fraction, percent, context…} → ReaderPosition + (flagged) Kindle write-back job
- `GET  /books/:id/read/state`         poll: web position + latest physical Kindle position (+ snippet to locate)
- `GET/POST/PATCH/DELETE /books/:id/read/annotations…`  web highlights/notes + Kindle-clippings merge; `locate` caches client-resolved CFIs
- `GET  /lookup?word=&lang=`           LookupsController — dictionary.sqlite3 (BookSearch pattern), server-side lemmatization

Data: `reader_positions` (book,user unique; cfi/fraction/percent/context JSON);
`devices.kind` (`kindle|web`) + `devices.reader_writeback`; synthetic "Folio
Web" Device row owns the web-side `reading_states` bundles; `annotations` gains
`source` (`clippings|web`), `cfi`, `color`, `note`.

Services: `Library::Krds` (full typed-stream parser/serializer, round-trip
byte-identical on the real fixtures in `spec/fixtures/sidecars/`),
`Library::PalmDoc`, `Library::Mobi.raw_text`, `Reader::Anchor`
(offset↔snippet, exact then fuzzy locate), `Reader::KindleWriteback` (rebuild
tar.gz bundle from latest physical bundle, rewrite positions only, abort if
basis went stale), `Dictionary` (+ ETL script).

kindled 0.2.3 (phase 3): during the FAST_POLL awake tick also stat local `.sdr`
dirs and trigger a full sync when they changed → Kindle→web latency drops from
≤300 s to ≤30 s.

## Phases

1. **Foundations** — schema+routes; reader core (vendor foliate-js, controller,
   layout, streaming, Stimulus reader, per-user position save); reader chrome
   (tap zones, TOC, settings, slider, fullscreen, loc numbers, Read button);
   KRDS/PalmDoc/rawml + anchor/write-back services; dictionary backend.
2. **Integration** — state poll + write-back wiring + sync prompts UX;
   annotations backend/UI (selection toolbar, overlays, drawer, clippings
   matching); lookup popup card (+ opt-in Wikipedia panel).
3. **kindled fast-push** (Rust, independent).
4. **Review & verify** — full rspec, cargo build/test, Playwright smoke of the
   reader, multi-lens code review, fixes.

Out of scope v1 (explicit): writing web highlights back into the Kindle's KRDS
annotation cache (interval tree — phase 2+ candidate), offline/PWA caching of
books, PDF reading (attempted only if foliate's vendored pdf.js works cheaply),
translation card.
