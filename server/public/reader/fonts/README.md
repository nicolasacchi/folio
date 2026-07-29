# Reader webfonts

Hosted under `/reader/fonts/<key>/` and injected into book iframes via
`@font-face` in `reader_controller.js` (absolute same-origin URLs).

Expected files per family key (`literata`, `bitter`, `garamond`, `atkinson`,
`opendyslexic`):

- `<key>-regular.woff2` (weight 400, normal)
- `<key>-italic.woff2` (weight 400, italic)
- `<key>-700.woff2` (weight 700, normal)
- `<key>-700italic.woff2` (weight 700, italic)

Exception: OpenDyslexic ships no bold-italic face anywhere upstream, so
`opendyslexic` has only the first three (browsers synthesize bold-italic)
and its WEBFONT_FACES entry lists just those.

Each family dir carries its OFL.txt license (all five are SIL OFL).
Missing files degrade silently (browser falls back to the stack's system
fonts).

Sources: Literata / Bitter / EB Garamond / Atkinson Hyperlegible via
google-webfonts-helper (latin + latin-ext subsets); OpenDyslexic from the
open-dyslexic npm package, converted woff → woff2 with fonttools.
