import { Controller } from "@hotwired/stimulus"
import { Overlayer } from "foliate-overlayer"

// Hosts a <foliate-view> and wires it up to Folio's reading-position API,
// plus the Kindle-style reading chrome: tap zones, top/bottom overlay
// bars, TOC/search/annotations panels, settings sheet, and annotations
// (selection menu, highlight/underline overlays, popover, drawer).
const SAVE_DEBOUNCE_MS = 2000
const SEARCH_DEBOUNCE_MS = 350
const SELECTION_DEBOUNCE_MS = 120
const AUTO_HIDE_MS = 4000

// A tap that moved the pointer further than this before release is a
// swipe/drag, not a tap — see bindTapZone().
const TAP_DRAG_THRESHOLD_PX = 12
const LEFT_ZONE = 0.3
const RIGHT_ZONE = 0.7

// A byte-per-location estimate in the same ballpark as the Kindle
// firmware's own "locations" unit (there is no public exact constant;
// 150 bytes/location is the commonly cited approximation).
const BYTES_PER_LOCATION = 150

const SETTINGS_KEY = "folio.reader.settings"
const DEFAULT_SETTINGS = {
  fontSize: 100, // percent
  lineHeight: 1.5,
  margin: 24, // px, injected into the book's own document
  theme: "light", // light | sepia | dark
  flow: "paginated" // paginated | scrolled
}

// Literal colors, not var(--token) — this CSS is injected into each
// section's own (cross-document, sandboxed-iframe) document via
// renderer.setStyles, which does not inherit our page's :root custom
// properties. Values mirror application.css's --paper/--ink tokens;
// "sepia" has no app-wide equivalent so it's defined only here.
const THEMES = {
  light: { background: "#f4efe3", color: "#221c12", link: "#b5442b" },
  sepia: { background: "#f2e6d0", color: "#3b2f1f", link: "#8a4b28" },
  dark: { background: "#171310", color: "#eae2cf", link: "#d97250" }
}

// Highlight colors offered by the selection menu — order and values mirror
// Annotation::COLORS server-side. Also literal (not var(--token)): these
// are handed to Overlayer.highlight/underline, which set them as raw SVG
// `fill`/`stroke` attributes inside each section's own sandboxed document,
// so they need to read reasonably on any of the three reader themes at
// once rather than being theme-reactive. Keep in sync with the
// `.reader-selection-dot--*` swatches in reader.css.
const HIGHLIGHT_COLORS = [ "yellow", "blue", "pink", "orange" ]
const COLOR_HEX = { yellow: "#f0c33c", blue: "#5a93d6", pink: "#e17ea6", orange: "#e2883f" }

// Selection text is capped before being sent as a highlight/note's
// `content` — long selections are unlikely to be useful excerpts and this
// keeps requests small.
const MAX_HIGHLIGHT_CONTENT_LENGTH = 1000

// Clippings-imported (source "clippings") highlight rows have no CFI of
// their own; resolving one takes a full-book text search, so this is
// capped and done a few at a time in the background — see
// resolveKindleAnnotationsInBackground().
const MAX_LAZY_LOCATE_ROWS = 30

// Kindle-style "quick define": a fresh selection this short fetches its
// definition immediately (see maybeAutoLookup()) rather than waiting for
// an explicit "Look up" tap.
const LOOKUP_AUTO_MAX_WORDS = 2
const LOOKUP_AUTO_MAX_CHARS = 30

// Wikipedia panel is off until the user opts in once, per browser — see
// ensureWikipediaPane()/enableWikipedia().
const WIKIPEDIA_CONSENT_KEY = "folio.reader.wikipedia"

// -- Kindle sync (position context capture, open-time sync, live poll) --

// context.exact/before/after target lengths — see buildPositionContext().
// Raw text is walked a bit past each target (CONTEXT_WALK_SLACK) so that
// collapsing whitespace afterward still leaves roughly this many chars.
const CONTEXT_EXACT_CHARS = 150
const CONTEXT_BEFORE_CHARS = 100
const CONTEXT_AFTER_CHARS = 100
const CONTEXT_WALK_SLACK = 60

// How far below (open-time sync)/above (live poll) the Kindle's percent
// has to sit relative to the web position before we surface it — mirrors
// ReaderController::BACKWARD_SLACK_PERCENT server-side (a different
// direction/purpose, same order of magnitude to avoid noisy prompts for
// a percent-rounding wobble).
const SYNC_PERCENT_SLACK = 0.5

const LIVE_POLL_INTERVAL_MS = 30_000
const LIVE_POLL_MAX_FAILURES = 3
const SYNC_TOAST_AUTO_DISMISS_MS = 15_000

// search.js/text-walker.js aren't pinned in importmap.rb (only the four
// modules the reader imports directly are) — needed here, dynamically,
// for the background clippings-locate pass, which deliberately avoids
// view.search() (that mutates the single shared search-panel state; see
// resolveKindleAnnotationsInBackground()). Keep this in sync with
// importmap.rb's foliate-js directory pin if that ever bumps.
const FOLIATE_JS_BASE = "/reader/foliate-js-78914ae"

export default class extends Controller {
  static targets = [
    "viewport", "loading",
    "topBar", "bottomBar", "progressSlider", "readout",
    "backdrop",
    "tocPanel", "tocList",
    "searchPanel", "searchInput", "searchStatus", "searchResults",
    "settingsPanel", "fontSizeReadout", "lineHeightSlider", "lineHeightReadout",
    "marginSlider", "marginReadout", "themeButton", "flowButton",
    "fullscreenButton",
    "selectionMenu",
    "annotationPopover", "annotationPopoverBody",
    "noteSheet", "noteTextarea",
    "annotationsPanel", "annotationsList",
    "lookupCard", "lookupTabDictionary", "lookupTabWikipedia",
    "lookupDictionaryPane", "lookupWikipediaPane",
    "syncBanner", "syncToast"
  ]
  static values = {
    fileUrl: String,
    filename: String,
    format: String,
    positionUrl: String,
    annotationsUrl: String,
    lookupUrl: String,
    stateUrl: String,
    bookLang: { type: String, default: "en" },
    csrfToken: String,
    cfi: String,
    fraction: Number,
    textLength: Number
  }

  connect() {
    this.pendingPosition = null
    this.saveTimer = null
    this.autoHideTimer = null
    this.searchDebounceTimer = null
    this.searchToken = 0
    this.sliderDragging = false
    this.boundDocs = new WeakSet()
    this.settings = this.loadSettings()

    // Annotations state — see the "-- Annotations --" section below.
    this.docIndex = new WeakMap()
    this.selectionBoundDocs = new WeakSet()
    this.selectionState = null
    this.selectionChangeTimer = null
    this.currentPopoverRow = null
    this.pendingNoteContext = null
    this.annotations = []
    this.annotationsById = new Map()
    this.annotationsByCfi = new Map()
    this.lazyLocateToken = 0

    // Dictionary/Wikipedia lookup card state — see the "-- Dictionary
    // lookup card --" section below.
    this.lookupState = null
    this.lookupToken = 0
    this.wikipediaToken = 0
    this.wikipediaEnabled = this.loadWikipediaConsent()

    // Kindle sync state — see the "-- Kindle sync --" section below.
    this.currentFraction = this.hasFractionValue ? this.fractionValue : 0
    this.kindleMtimeBaseline = null
    this.pollTimer = null
    this.pollFailures = 0
    this.syncToastTimer = null
    this.backwardPromptDismissed = false

    this.onKeydown = this.onKeydown.bind(this)
    document.addEventListener("keydown", this.onKeydown)
    this.onFullscreenChange = this.onFullscreenChange.bind(this)
    document.addEventListener("fullscreenchange", this.onFullscreenChange)
    this.onReaderLookup = (event) => this.openLookupCard(event.detail)
    this.element.addEventListener("reader:lookup", this.onReaderLookup)
    this.onDocumentPointerDown = (event) => this.handleOutsideLookupPointerDown(event)
    document.addEventListener("pointerdown", this.onDocumentPointerDown)
    this.onVisibilityChange = () => this.handleVisibilityChange()
    document.addEventListener("visibilitychange", this.onVisibilityChange)
    // Reliable fallback for a real navigation-away (a `data-turbo="false"`
    // link, tab close, OS backgrounding a mobile tab/PWA) that discards the
    // whole document+JS realm before Stimulus's disconnect() (which only
    // fires on removal from a still-live document) ever gets a chance to
    // run — see flushPosition()'s keepalive fetch, which is what lets this
    // save actually complete after the page starts going away.
    this.onPageHide = () => this.flushPosition()
    window.addEventListener("pagehide", this.onPageHide)

    if (this.hasFullscreenButtonTarget) {
      this.fullscreenButtonTarget.hidden = !(document.fullscreenEnabled && this.element.requestFullscreen)
    }

    this.applyChromeTheme()
    this.renderSettingsUI()
    this.bindTapZone(this.viewportTarget)
    this.open()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("fullscreenchange", this.onFullscreenChange)
    this.element.removeEventListener("reader:lookup", this.onReaderLookup)
    document.removeEventListener("pointerdown", this.onDocumentPointerDown)
    document.removeEventListener("visibilitychange", this.onVisibilityChange)
    window.removeEventListener("pagehide", this.onPageHide)
    this.clearAutoHide()
    this.clearLivePoll()
    if (this.saveTimer) clearTimeout(this.saveTimer)
    if (this.searchDebounceTimer) clearTimeout(this.searchDebounceTimer)
    if (this.selectionChangeTimer) clearTimeout(this.selectionChangeTimer)
    if (this.syncToastTimer) clearTimeout(this.syncToastTimer)
    this.lazyLocateToken += 1 // abort any in-flight background clippings-locate pass
    this.lookupToken += 1 // abort any in-flight /lookup fetch
    this.wikipediaToken += 1 // abort any in-flight Wikipedia fetch
    this.flushPosition()
  }

  // -- Opening the book --------------------------------------------------

  async open() {
    try {
      this.showLoading()
      const response = await fetch(this.fileUrlValue)
      if (!response.ok) throw new Error(`fetch ${this.fileUrlValue} -> ${response.status}`)
      const blob = await response.blob()
      const file = new File([ blob ], this.filenameValue || "book")

      // Importing registers the <foliate-view> custom element as a
      // side effect (view.js: `customElements.define('foliate-view', View)`).
      await import("foliate-view")

      this.view = document.createElement("foliate-view")
      this.viewportTarget.replaceChildren(this.view)

      // Each section renders in its own sandboxed iframe/document, which
      // never bubbles click/pointer events to this page — so tap zones
      // and text-selection handling need fresh listeners bound directly
      // inside every new document.
      this.view.addEventListener("load", (event) => {
        const { doc, index } = event.detail
        this.docIndex.set(doc, index)
        this.bindDocTapZone(doc)
        this.bindDocSelection(doc)
      })

      await this.view.open(file)
      this.applyFlow()
      this.applyContentStyles()
      this.view.addEventListener("relocate", (event) => this.onRelocate(event))
      this.view.addEventListener("draw-annotation", (event) => this.onDrawAnnotation(event))
      this.view.addEventListener("show-annotation", (event) => this.onShowAnnotation(event))
      // Fires once a section's overlayer is ready to draw into — see the
      // long comment on redrawAnnotations() for why this (rather than
      // drawing straight from the 'load' handler above) is required.
      this.view.addEventListener("create-overlay", () => this.redrawAnnotations())

      const lastLocation = this.hasCfiValue && this.cfiValue
        ? this.cfiValue
        : (this.hasFractionValue && this.fractionValue > 0 ? { fraction: this.fractionValue } : null)
      await this.view.init({ lastLocation, showTextStart: !lastLocation })

      this.populateToc()
      this.loadAnnotations() // not awaited — runs in the background, doesn't delay first paint
      this.hideLoading()

      this.syncWithKindleOnOpen() // not awaited — background banner/auto-jump, doesn't delay first paint
      this.armLivePoll()
    } catch (error) {
      console.error("[reader] failed to open book", error)
      this.showError()
    }
  }

  retry() {
    this.view?.close?.()
    this.view = null
    this.boundDocs = new WeakSet()
    this.selectionBoundDocs = new WeakSet()
    this.docIndex = new WeakMap()
    this.lazyLocateToken += 1
    this.annotations = []
    this.annotationsById = new Map()
    this.annotationsByCfi = new Map()
    this.open()
  }

  // -- Tap zones: left/right ~30% pages, the middle toggles chrome -------

  bindTapZone(target) {
    let startX = 0
    let startY = 0
    let dragDistance = 0

    const onDown = (event) => {
      startX = event.clientX
      startY = event.clientY
      dragDistance = 0
    }
    const onMove = (event) => {
      dragDistance = Math.max(dragDistance, Math.hypot(event.clientX - startX, event.clientY - startY))
    }
    // A plain click (not pointerup) so a link's own click handler — which
    // runs first on the same document and calls preventDefault — has
    // already had a chance to consume the tap before we see it.
    const onClick = (event) => {
      if (dragDistance > TAP_DRAG_THRESHOLD_PX) return
      if (event.defaultPrevented) return

      const isDocument = target.nodeType === Node.DOCUMENT_NODE
      const selection = isDocument ? target.defaultView?.getSelection?.() : target.ownerDocument?.getSelection?.()
      if (selection && !selection.isCollapsed) return

      // Authoritative check for "this tap landed on an existing highlight/
      // underline", independent of listener registration order: ours binds
      // on the view's 'load' event (see open(), above), while foliate-js's
      // own overlay hit-test listener binds later, on 'create-overlay' (see
      // View#createOverlayer in view.js) — so on the *first* tap of a given
      // highlight, isAnnotationPopoverOpen() below would still be judging
      // the previous tap, not this one, and we'd turn the page right before
      // foliate-js's own (later-run) listener opens the popover underneath
      // it. Overlayer#hitTest (overlayer.js) is public API built for
      // exactly this, so ask it directly instead of relying on ordering.
      if (isDocument && this.tappedAnnotation(target, event)) return

      const width = isDocument ? target.defaultView?.innerWidth : target.clientWidth
      if (!width) return
      const x = isDocument ? event.clientX : event.clientX - target.getBoundingClientRect().left
      this.onZoneTap(x / width)
    }

    target.addEventListener("pointerdown", onDown, { passive: true })
    target.addEventListener("pointermove", onMove, { passive: true })
    target.addEventListener("click", onClick)
  }

  bindDocTapZone(doc) {
    if (!doc || this.boundDocs.has(doc)) return
    this.boundDocs.add(doc)
    this.bindTapZone(doc)
  }

  // doc's current overlayer (once foliate-js has created one for it — see
  // the 'create-overlay' comment above) exposes hitTest({x, y}); a
  // MouseEvent's own .x/.y are standard aliases for clientX/clientY, so it
  // can be passed straight through, same as foliate-js's own call. Also
  // (harmlessly) swallows a tap on a live search-result marker, which has
  // no popover of its own to protect — an acceptable trade-off against
  // duplicating view.js's private SEARCH_PREFIX check here.
  tappedAnnotation(doc, event) {
    const section = this.view?.renderer?.getContents().find((content) => content.doc === doc)
    const [ value ] = section?.overlayer?.hitTest(event) || []
    return Boolean(value)
  }

  onZoneTap(ratio) {
    // A tap that lands on an existing highlight/underline also reaches
    // View's own overlay hit-test listener (bound after ours — see the
    // 'show-annotation' handler below), which opens the popover; treat an
    // already-open popover as "this tap was about the annotation" and
    // swallow it here rather than also turning the page underneath it.
    // (tappedAnnotation() above already stops *this* tap from acting on the
    // page; this covers a *subsequent* tap while that popover is still up.)
    if (this.isAnnotationPopoverOpen()) {
      this.closeAnnotationPopover()
      return
    }
    // Same swallow-the-tap treatment as the annotation popover above: a tap
    // while the lookup card is showing dismisses it (and the selection menu
    // it's attached to) rather than also turning the page underneath it.
    if (this.isLookupCardOpen()) {
      this.closeLookupCard()
      this.hideSelectionMenu()
      return
    }
    if (ratio < LEFT_ZONE) this.prevPage()
    else if (ratio > RIGHT_ZONE) this.nextPage()
    else this.toggleChrome()
  }

  prevPage() {
    this.view?.goLeft()
  }

  nextPage() {
    this.view?.goRight()
  }

  onKeydown(event) {
    if (event.key === "Escape") {
      if (this.hasOpenPanel()) {
        this.closePanels()
        return
      }
      if (this.isLookupCardOpen()) {
        this.closeLookupCard()
        return
      }
      if (this.isAnnotationPopoverOpen()) {
        this.closeAnnotationPopover()
        return
      }
      if (this.isSelectionMenuOpen()) {
        this.hideSelectionMenu()
        return
      }
      if (this.isSyncToastOpen()) {
        this.closeSyncToast()
        return
      }
      if (this.isSyncBannerOpen()) {
        this.dismissSyncBanner(this.syncBannerTarget.dataset.syncBannerKind)
        return
      }
    }
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return
    if (!this.view) return

    if (event.key === "ArrowLeft") {
      event.preventDefault()
      this.prevPage()
    } else if (event.key === "ArrowRight" || event.key === " ") {
      event.preventDefault()
      this.nextPage()
    }
  }

  // -- Chrome (top/bottom overlay bars) -----------------------------------

  showChrome() {
    this.element.classList.add("reader-chrome-visible")
    this.scheduleAutoHide()
  }

  hideChrome() {
    if (this.hasOpenPanel()) return
    this.element.classList.remove("reader-chrome-visible")
    this.clearAutoHide()
  }

  toggleChrome() {
    if (this.element.classList.contains("reader-chrome-visible")) this.hideChrome()
    else this.showChrome()
  }

  scheduleAutoHide() {
    this.clearAutoHide()
    this.autoHideTimer = setTimeout(() => this.hideChrome(), AUTO_HIDE_MS)
  }

  clearAutoHide() {
    if (this.autoHideTimer) clearTimeout(this.autoHideTimer)
    this.autoHideTimer = null
  }

  // -- Panels: TOC drawer, search drawer, annotations drawer, settings
  //    sheet, note sheet ---------------------------------------------------

  panelElements() {
    return [
      this.tocPanelTarget, this.searchPanelTarget, this.settingsPanelTarget,
      this.annotationsPanelTarget, this.noteSheetTarget
    ]
  }

  hasOpenPanel() {
    return this.element.classList.contains("reader-panel-open")
  }

  openPanel(panelTarget) {
    for (const panel of this.panelElements()) {
      panel.classList.toggle("is-open", panel === panelTarget)
    }
    this.backdropTarget.classList.add("is-open")
    this.element.classList.add("reader-panel-open")
    this.hideSelectionMenu()
    this.closeAnnotationPopover()
    this.closeLookupCard()
    this.closeSyncBanner()
    this.closeSyncToast()
    this.showChrome()
    this.clearAutoHide()
  }

  closePanels() {
    for (const panel of this.panelElements()) {
      panel.classList.remove("is-open")
    }
    this.backdropTarget.classList.remove("is-open")
    this.element.classList.remove("reader-panel-open")
    this.pendingNoteContext = null
    this.searchToken += 1
    this.view?.clearSearch()
    this.scheduleAutoHide()
  }

  // -- TOC ------------------------------------------------------------

  openToc() {
    this.populateToc()
    this.openPanel(this.tocPanelTarget)
  }

  populateToc() {
    if (!this.hasTocListTarget) return
    this.tocListTarget.replaceChildren()
    const toc = this.view?.book?.toc
    if (!toc || !toc.length) {
      const empty = document.createElement("p")
      empty.className = "reader-empty-note"
      empty.textContent = "No table of contents."
      this.tocListTarget.append(empty)
      return
    }
    this.tocListTarget.append(this.buildTocList(toc))
  }

  buildTocList(items) {
    const ul = document.createElement("ul")
    ul.className = "reader-toc-tree"
    for (const item of items) {
      const li = document.createElement("li")
      const a = document.createElement("a")
      a.href = "#"
      a.textContent = item.label?.trim() || "Untitled"
      a.dataset.tocId = item.id
      a.dataset.href = item.href
      a.setAttribute("data-action", "click->reader#goToTocItem")
      li.append(a)
      if (item.subitems?.length) li.append(this.buildTocList(item.subitems))
      ul.append(li)
    }
    return ul
  }

  goToTocItem(event) {
    event.preventDefault()
    const href = event.currentTarget.dataset.href
    if (href) this.view?.goTo(href)
    this.closePanels()
  }

  updateTocHighlight(tocItem) {
    if (!this.hasTocListTarget) return
    this.tocListTarget.querySelectorAll(".is-current").forEach((el) => el.classList.remove("is-current"))
    if (tocItem == null) return
    const current = this.tocListTarget.querySelector(`a[data-toc-id="${tocItem.id}"]`)
    current?.classList.add("is-current")
  }

  // -- Search -----------------------------------------------------------

  openSearch() {
    this.openPanel(this.searchPanelTarget)
    this.searchInputTarget?.focus()
  }

  onSearchInput(event) {
    const query = event.target.value.trim()
    if (this.searchDebounceTimer) clearTimeout(this.searchDebounceTimer)
    this.searchDebounceTimer = setTimeout(() => {
      this.searchToken += 1
      this.runSearch(query, this.searchToken)
    }, SEARCH_DEBOUNCE_MS)
  }

  async runSearch(query, token) {
    if (!this.view) return
    this.searchResultsTarget.replaceChildren()
    if (!query) {
      this.searchStatusTarget.textContent = ""
      this.view.clearSearch()
      return
    }

    this.searchStatusTarget.textContent = "Searching…"
    try {
      let found = false
      for await (const result of this.view.search({ query })) {
        if (token !== this.searchToken) return // superseded by a newer search

        if (result === "done") {
          this.searchStatusTarget.textContent = found ? "" : "No matches."
          return
        }
        if (result.subitems) {
          found = true
          this.appendSearchGroup(result)
        } else if (typeof result.progress === "number") {
          this.searchStatusTarget.textContent = `Searching… ${Math.round(result.progress * 100)}%`
        }
      }
    } catch (error) {
      console.error("[reader] search failed", error)
      if (token === this.searchToken) this.searchStatusTarget.textContent = "Search failed."
    }
  }

  appendSearchGroup({ label, subitems }) {
    const group = document.createElement("div")
    group.className = "reader-search-group"

    const heading = document.createElement("h3")
    heading.textContent = label || "Untitled section"
    group.append(heading)

    for (const { cfi, excerpt } of subitems) {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "reader-search-hit"
      button.dataset.cfi = cfi
      button.setAttribute("data-action", "click->reader#goToSearchResult")

      const p = document.createElement("p")
      p.append(document.createTextNode(excerpt.pre))
      const mark = document.createElement("mark")
      mark.textContent = excerpt.match
      p.append(mark)
      p.append(document.createTextNode(excerpt.post))
      button.append(p)

      group.append(button)
    }

    this.searchResultsTarget.append(group)
  }

  goToSearchResult(event) {
    const cfi = event.currentTarget.dataset.cfi
    if (cfi) this.view?.goTo(cfi)
    this.closePanels()
  }

  // -- Text selection: floating menu --------------------------------------
  //
  // selectionchange fires on each section's own (sandboxed-iframe) document,
  // never on ours, so — like tap zones — it has to be bound fresh per
  // section doc from the 'load' handler in open(). pointerup/touchend show
  // the menu the moment a selection is made; the debounced selectionchange
  // listener re-shows it as the user drags the native selection handles
  // (notably on iOS, where handle drags don't fire pointerup on release).

  bindDocSelection(doc) {
    if (!doc || this.selectionBoundDocs.has(doc)) return
    this.selectionBoundDocs.add(doc)

    const onInteract = () => this.evaluateSelection(doc)
    doc.addEventListener("pointerup", onInteract, { passive: true })
    doc.addEventListener("touchend", onInteract, { passive: true })
    doc.addEventListener("selectionchange", () => {
      if (this.selectionChangeTimer) clearTimeout(this.selectionChangeTimer)
      this.selectionChangeTimer = setTimeout(() => this.evaluateSelection(doc), SELECTION_DEBOUNCE_MS)
    })
  }

  evaluateSelection(doc) {
    const selection = doc.defaultView?.getSelection?.()
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed || !selection.toString().trim()) {
      this.hideSelectionMenu()
      this.closeLookupCard()
      return
    }
    const index = this.docIndex.get(doc)
    if (index == null) {
      this.hideSelectionMenu()
      return
    }
    this.selectionState = { doc, index }
    const range = selection.getRangeAt(0)
    this.showSelectionMenu(range)
    this.maybeAutoLookup(doc, range, selection.toString().trim())
  }

  // Re-reads the live selection at action time (rather than trusting a
  // Range captured earlier) — selecting text inside the section iframe
  // doesn't lose focus/selection when the user then taps a host-page
  // button, so the selection is still live when e.g. highlightSelection()
  // runs.
  captureSelectionText() {
    const state = this.selectionState
    if (!state) return null
    const selection = state.doc.defaultView?.getSelection?.()
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null
    const text = selection.toString()
    if (!text.trim()) return null
    return { doc: state.doc, index: state.index, range: selection.getRangeAt(0), text }
  }

  showSelectionMenu(range) {
    if (!this.hasSelectionMenuTarget) return
    const rect = this.hostRectForRange(range)
    if (!rect) {
      this.hideSelectionMenu()
      return
    }
    this.positionFloating(this.selectionMenuTarget, rect)
    this.selectionMenuTarget.classList.add("is-open")
  }

  hideSelectionMenu() {
    if (this.hasSelectionMenuTarget) this.selectionMenuTarget.classList.remove("is-open")
    this.selectionState = null
  }

  isSelectionMenuOpen() {
    return this.hasSelectionMenuTarget && this.selectionMenuTarget.classList.contains("is-open")
  }

  // Translates a Range's rects — which come from getClientRects() and are
  // relative to the section's own sandboxed-iframe viewport — into this
  // (top-level) document's viewport coordinates, for positioning host-page
  // floating UI (selection menu, annotation popover). The section iframe
  // has zero border/padding (see foliate-js's paginator.js View class), so
  // simply adding the iframe's own getBoundingClientRect() offset to the
  // in-iframe rect works for both paginated (columnized) and scrolled
  // flow, and regardless of how much the section is internally offset by
  // pagination/scroll — getBoundingClientRect() already nets that out.
  // `allow-same-origin` on the section iframe's sandbox (needed for
  // scripting anyway) is what makes `frameElement` reachable at all here.
  hostRectForRange(range) {
    const doc = range?.startContainer?.ownerDocument
    const frame = doc?.defaultView?.frameElement
    if (!frame) return null
    const rects = Array.from(range.getClientRects())
    if (!rects.length) return null

    const frameRect = frame.getBoundingClientRect()
    const left = Math.min(...rects.map((r) => r.left))
    const right = Math.max(...rects.map((r) => r.right))
    const top = Math.min(...rects.map((r) => r.top))
    const bottom = Math.max(...rects.map((r) => r.bottom))
    return {
      left: frameRect.left + left,
      right: frameRect.left + right,
      top: frameRect.top + top,
      bottom: frameRect.top + bottom,
      width: right - left,
      height: bottom - top
    }
  }

  // Shared positioning for both the selection menu and the annotation
  // popover: centers on the anchor rect, flips above/below to stay on
  // screen, and clamps horizontally. (On narrow viewports the annotation
  // popover overrides this via a CSS media query into a bottom sheet —
  // see reader.css — so this is mainly load-bearing on wider screens.)
  positionFloating(el, anchorRect) {
    const margin = 8
    const elRect = el.getBoundingClientRect()
    const width = elRect.width || 240
    const height = elRect.height || 44
    const viewportWidth = window.innerWidth
    const viewportHeight = window.innerHeight

    let left = anchorRect.left + anchorRect.width / 2 - width / 2
    left = Math.max(margin, Math.min(left, viewportWidth - width - margin))

    let top = anchorRect.top - height - margin
    if (top < margin) top = anchorRect.bottom + margin
    top = Math.max(margin, Math.min(top, viewportHeight - height - margin))

    el.style.left = `${Math.round(left)}px`
    el.style.top = `${Math.round(top)}px`
  }

  // Re-clamps the lookup card against the anchor rect it was opened with.
  // openLookupCard() only positions it once, before its async dictionary/
  // Wikipedia content (shimmer -> result, or a tab switch showing a
  // differently-sized pane) has loaded — a short initial measurement
  // followed by a much taller result can otherwise push the card's bottom
  // edge past the viewport with nothing to bring it back on screen. A
  // no-op once the card is closed (lookupState cleared) or on narrow
  // viewports where reader.css's bottom-sheet override ignores the inline
  // left/top this sets anyway.
  repositionLookupCard() {
    if (!this.hasLookupCardTarget || !this.lookupState?.anchorRect) return
    this.positionFloating(this.lookupCardTarget, this.lookupState.anchorRect)
  }

  // -- Highlight / note creation from the selection menu -------------------

  async highlightSelection(event) {
    const color = event.params.color
    const captured = this.captureSelectionText()
    this.hideSelectionMenu()
    this.view?.deselect()
    if (!captured) return

    const cfi = this.view.getCFI(captured.index, captured.range)
    const content = captured.text.trim().slice(0, MAX_HIGHLIGHT_CONTENT_LENGTH)
    const row = await this.createAnnotation({ kind: "highlight", cfi, content, color })
    if (!row) return
    this.upsertAnnotationState(row)
    await this.drawAnnotationRow(row)
    this.renderAnnotationsList()
  }

  noteSelection() {
    const captured = this.captureSelectionText()
    this.hideSelectionMenu()
    if (!captured) return

    const cfi = this.view.getCFI(captured.index, captured.range)
    const content = captured.text.trim().slice(0, MAX_HIGHLIGHT_CONTENT_LENGTH)
    this.view?.deselect()
    this.openNoteSheetForCreate(cfi, content)
  }

  async copySelection() {
    const captured = this.captureSelectionText()
    this.hideSelectionMenu()
    if (!captured) return
    try {
      await navigator.clipboard.writeText(captured.text.trim())
    } catch (error) {
      console.error("[reader] copy failed", error)
    }
  }

  // Look-up hand-off: dispatched on this.element (bubbles) as
  // "reader:lookup" with `{ word, lang, rect }` — `rect` is already
  // translated into this document's viewport ({left, top, right, bottom,
  // width, height}, position:fixed-compatible). `word` is the raw trimmed
  // selection (may be a phrase, not a single token) and `lang` is the
  // book's own section language when set, else null. This selection menu
  // button doesn't itself call /lookup — openLookupCard(), below, is the
  // sole listener and does that (kept as an event rather than a direct
  // call so the hand-off contract stays decoupled from how the card ends
  // up wired). The menu is deliberately left open: its color dots/Note/Copy
  // stay reachable while the card is showing, Kindle-style.
  lookupSelection() {
    const captured = this.captureSelectionText()
    if (!captured) return
    const text = captured.text.trim()
    if (!text) return
    this.dispatchLookup({ word: text, lang: captured.doc.documentElement?.lang || null, rect: this.hostRectForRange(captured.range) })
  }

  // -- Dictionary lookup card ----------------------------------------------
  //
  // Two entry points funnel into openLookupCard() via the "reader:lookup"
  // event: the selection menu's explicit "Look up" button (lookupSelection(),
  // above) and auto-mode for short selections (maybeAutoLookup(), called
  // from evaluateSelection()). The card anchors to the *selection menu's*
  // own rect (not the raw selection rect) whenever the menu is showing,
  // so it stacks below/above the menu instead of covering it — the menu is
  // always shown first in both entry points, so this is the common case;
  // the raw rect from the event is only a fallback.

  dispatchLookup(detail) {
    this.element.dispatchEvent(new CustomEvent("reader:lookup", { bubbles: true, detail }))
  }

  maybeAutoLookup(doc, range, text) {
    if (!this.isAutoLookupCandidate(text)) return
    this.dispatchLookup({ word: text, lang: doc.documentElement?.lang || null, rect: this.hostRectForRange(range) })
  }

  isAutoLookupCandidate(text) {
    if (!text || text.length > LOOKUP_AUTO_MAX_CHARS) return false
    const words = text.split(/\s+/).filter(Boolean)
    return words.length >= 1 && words.length <= LOOKUP_AUTO_MAX_WORDS
  }

  openLookupCard({ word, lang, rect } = {}) {
    if (!this.hasLookupCardTarget) return
    const cleanWord = (word || "").trim()
    if (!cleanWord) return

    const resolvedLang = this.normalizeLookupLang(lang) || this.bookLangValue || "en"
    const previous = this.lookupState
    const sameWord = previous?.word === cleanWord
    const activeTab = sameWord ? previous.activeTab : "dictionary"
    // word::lang -- shared by both dictionaryFetchedFor and
    // wikipediaFetchedFor, so a language change (same literal selected
    // word, different resolvedLang) always refetches both instead of
    // wikipedia's fetch being skipped as a false cache hit on the bare word.
    const lookupKey = `${cleanWord}::${resolvedLang}`
    const needsDictionaryFetch = previous?.dictionaryFetchedFor !== lookupKey

    const anchorRect = this.isSelectionMenuOpen() ? this.selectionMenuTarget.getBoundingClientRect() : rect

    this.lookupState = {
      word: cleanWord,
      lang: resolvedLang,
      activeTab,
      dictionaryFetchedFor: needsDictionaryFetch ? null : lookupKey,
      wikipediaFetchedFor: previous?.wikipediaFetchedFor === lookupKey ? lookupKey : null,
      anchorRect // re-used by repositionLookupCard() once async content changes the card's height
    }

    if (anchorRect) this.positionFloating(this.lookupCardTarget, anchorRect)
    this.lookupCardTarget.classList.add("is-open")
    this.setLookupTab(activeTab)

    if (needsDictionaryFetch) {
      this.lookupToken += 1
      this.fetchDictionaryEntry(this.lookupToken)
    }
    if (activeTab === "wikipedia") this.ensureWikipediaPane()
  }

  closeLookupCard() {
    if (this.hasLookupCardTarget) this.lookupCardTarget.classList.remove("is-open")
    this.lookupState = null
    this.lookupToken += 1
    this.wikipediaToken += 1
  }

  isLookupCardOpen() {
    return this.hasLookupCardTarget && this.lookupCardTarget.classList.contains("is-open")
  }

  // A pointerdown on the host page (chrome, backdrop, drawers…) outside
  // both the card and the selection menu it's attached to dismisses it —
  // taps *inside* a section iframe never reach this (separate document;
  // see bindDocTapZone/onZoneTap above for that path), and taps on the
  // menu itself (e.g. Note/Copy) are deliberately left alone.
  handleOutsideLookupPointerDown(event) {
    if (!this.isLookupCardOpen()) return
    const target = event.target
    if (this.hasLookupCardTarget && this.lookupCardTarget.contains(target)) return
    if (this.hasSelectionMenuTarget && this.selectionMenuTarget.contains(target)) return
    this.closeLookupCard()
  }

  // GET /lookup only understands Dictionary::SUPPORTED_LANGS ("en"/"it")
  // and falls back to "en" server-side for anything else — mirrored here
  // so a section's raw `lang` (possibly "en-US", "IT", empty…) resolves to
  // something the "try the other language" retry can actually offer.
  normalizeLookupLang(raw) {
    const code = (raw || "").toLowerCase().slice(0, 2)
    if (code === "it") return "it"
    if (code === "en") return "en"
    return null
  }

  showLookupDictionaryTab() {
    this.setLookupTab("dictionary")
  }

  showLookupWikipediaTab() {
    this.setLookupTab("wikipedia")
    this.ensureWikipediaPane()
  }

  setLookupTab(tab) {
    if (this.lookupState) this.lookupState.activeTab = tab
    if (this.hasLookupTabDictionaryTarget) {
      this.lookupTabDictionaryTarget.classList.toggle("is-active", tab === "dictionary")
      this.lookupTabDictionaryTarget.setAttribute("aria-pressed", String(tab === "dictionary"))
    }
    if (this.hasLookupTabWikipediaTarget) {
      this.lookupTabWikipediaTarget.classList.toggle("is-active", tab === "wikipedia")
      this.lookupTabWikipediaTarget.setAttribute("aria-pressed", String(tab === "wikipedia"))
    }
    if (this.hasLookupDictionaryPaneTarget) this.lookupDictionaryPaneTarget.hidden = tab !== "dictionary"
    if (this.hasLookupWikipediaPaneTarget) this.lookupWikipediaPaneTarget.hidden = tab !== "wikipedia"
    this.repositionLookupCard() // switching panes can change the card's height
  }

  async fetchDictionaryEntry(token) {
    const state = this.lookupState
    if (!state || !this.hasLookupDictionaryPaneTarget) return
    const { word, lang } = state
    const dictionaryKey = `${word}::${lang}`
    this.renderLookupShimmer(this.lookupDictionaryPaneTarget)
    try {
      const url = `${this.lookupUrlValue}?word=${encodeURIComponent(word)}&lang=${encodeURIComponent(lang)}`
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (token !== this.lookupToken) return // superseded by a newer lookup
      if (response.status === 404) {
        if (this.lookupState) this.lookupState.dictionaryFetchedFor = dictionaryKey
        this.renderLookupDictionaryNotFound(word, lang)
        return
      }
      if (!response.ok) throw new Error(`fetch ${url} -> ${response.status}`)
      const data = await response.json()
      if (token !== this.lookupToken) return
      if (this.lookupState) this.lookupState.dictionaryFetchedFor = dictionaryKey
      this.renderLookupDictionaryResult(data)
    } catch (error) {
      console.error("[reader] lookup failed", error)
      if (token === this.lookupToken) this.renderLookupDictionaryError()
    }
  }

  retryLookupOtherLang() {
    if (!this.lookupState) return
    this.lookupState.lang = this.lookupState.lang === "en" ? "it" : "en"
    this.lookupState.dictionaryFetchedFor = null
    this.lookupToken += 1
    this.fetchDictionaryEntry(this.lookupToken)
  }

  renderLookupShimmer(target) {
    if (!target) return
    const shimmer = document.createElement("div")
    shimmer.className = "reader-lookup-shimmer"
    for (let i = 0; i < 3; i++) {
      const line = document.createElement("div")
      line.className = "reader-lookup-shimmer__line"
      shimmer.append(line)
    }
    target.replaceChildren(shimmer)
  }

  renderLookupDictionaryResult(data) {
    if (!this.hasLookupDictionaryPaneTarget) return
    this.lookupDictionaryPaneTarget.replaceChildren(this.buildLookupDictionaryContent(data))
    this.repositionLookupCard()
  }

  // Built with DOM calls, not innerHTML — headword/lemma/glosses come from
  // the dictionary DB (ultimately Wiktionary-derived), not trusted enough
  // to interpolate into markup.
  buildLookupDictionaryContent(data) {
    const frag = document.createDocumentFragment()

    const head = document.createElement("div")
    head.className = "reader-lookup-head"
    const headword = document.createElement("span")
    headword.className = "reader-lookup-headword"
    headword.textContent = data.word
    head.append(headword)
    if (data.lemma && data.lemma !== data.word) {
      const arrow = document.createElement("span")
      arrow.className = "reader-lookup-lemma-arrow"
      arrow.textContent = "→"
      const lemma = document.createElement("span")
      lemma.className = "reader-lookup-lemma"
      lemma.textContent = data.lemma
      head.append(arrow, lemma)
    }
    frag.append(head)

    const entries = document.createElement("div")
    entries.className = "reader-lookup-entries"
    for (const entry of (data.entries || [])) {
      const entryEl = document.createElement("div")
      entryEl.className = "reader-lookup-entry"
      if (entry.pos) {
        const pos = document.createElement("span")
        pos.className = "reader-lookup-pos"
        pos.textContent = entry.pos
        entryEl.append(pos)
      }
      const glosses = document.createElement("ol")
      glosses.className = "reader-lookup-glosses"
      for (const gloss of (entry.glosses || [])) {
        const li = document.createElement("li")
        li.textContent = gloss
        glosses.append(li)
      }
      entryEl.append(glosses)
      entries.append(entryEl)
    }
    frag.append(entries)

    return frag
  }

  renderLookupDictionaryNotFound(word, lang) {
    if (!this.hasLookupDictionaryPaneTarget) return
    const frag = document.createDocumentFragment()

    const empty = document.createElement("p")
    empty.className = "reader-empty-note"
    empty.textContent = "No definition found."
    frag.append(empty)

    const otherLang = lang === "en" ? "it" : "en"
    const retry = document.createElement("button")
    retry.type = "button"
    retry.className = "btn btn--quiet"
    retry.textContent = otherLang === "en" ? "Try English" : "Try Italian"
    retry.setAttribute("data-action", "reader#retryLookupOtherLang")
    frag.append(retry)

    this.lookupDictionaryPaneTarget.replaceChildren(frag)
    this.repositionLookupCard()
  }

  renderLookupDictionaryError() {
    if (!this.hasLookupDictionaryPaneTarget) return
    const p = document.createElement("p")
    p.className = "reader-empty-note"
    p.textContent = "Couldn't load definition."
    this.lookupDictionaryPaneTarget.replaceChildren(p)
    this.repositionLookupCard()
  }

  // -- Wikipedia panel: off by default, opt-in persisted in localStorage --

  ensureWikipediaPane() {
    if (!this.lookupState) return
    if (!this.wikipediaEnabled) {
      this.renderLookupWikipediaConsent()
      return
    }
    if (this.lookupState.wikipediaFetchedFor === `${this.lookupState.word}::${this.lookupState.lang}`) return
    this.fetchWikipediaSummary()
  }

  enableWikipedia() {
    this.wikipediaEnabled = true
    try {
      window.localStorage.setItem(WIKIPEDIA_CONSENT_KEY, "1")
    } catch (error) {
      console.error("[reader] failed to persist wikipedia consent", error)
    }
    this.fetchWikipediaSummary()
  }

  loadWikipediaConsent() {
    try {
      return window.localStorage.getItem(WIKIPEDIA_CONSENT_KEY) === "1"
    } catch (error) {
      // Safari private mode (and similar) can throw on localStorage access.
      return false
    }
  }

  async fetchWikipediaSummary() {
    const state = this.lookupState
    if (!state || !this.hasLookupWikipediaPaneTarget) return
    const word = state.word
    const lang = state.lang || "en"
    const key = `${word}::${lang}` // mirrors dictionaryFetchedFor's word::lang keying
    this.wikipediaToken += 1
    const token = this.wikipediaToken
    this.renderLookupShimmer(this.lookupWikipediaPaneTarget)
    try {
      const url = `https://${lang}.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(word)}`
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (token !== this.wikipediaToken) return // superseded by a newer lookup
      if (response.status === 404) {
        this.renderLookupWikipediaNotFound()
        return
      }
      if (!response.ok) throw new Error(`fetch ${url} -> ${response.status}`)
      const data = await response.json()
      if (token !== this.wikipediaToken) return
      if (this.lookupState) this.lookupState.wikipediaFetchedFor = key
      this.renderLookupWikipediaResult(data)
    } catch (error) {
      console.error("[reader] wikipedia lookup failed", error)
      if (token === this.wikipediaToken) this.renderLookupWikipediaError()
    }
  }

  renderLookupWikipediaConsent() {
    if (!this.hasLookupWikipediaPaneTarget) return
    const wrap = document.createElement("div")
    wrap.className = "reader-lookup-consent"

    const text = document.createElement("p")
    text.className = "reader-lookup-consent__text"
    text.textContent = "Fetches from wikipedia.org"
    wrap.append(text)

    const enable = document.createElement("button")
    enable.type = "button"
    enable.className = "btn btn--primary"
    enable.textContent = "Enable"
    enable.setAttribute("data-action", "reader#enableWikipedia")
    wrap.append(enable)

    this.lookupWikipediaPaneTarget.replaceChildren(wrap)
  }

  // Built with DOM calls, not innerHTML — extract/title/thumbnail come
  // from Wikipedia's API, never trusted enough to interpolate into markup.
  renderLookupWikipediaResult(data) {
    if (!this.hasLookupWikipediaPaneTarget) return
    const wrap = document.createElement("div")
    wrap.className = "reader-lookup-wiki"

    if (data.thumbnail?.source) {
      const img = document.createElement("img")
      img.className = "reader-lookup-wiki__thumb"
      img.src = data.thumbnail.source
      img.alt = ""
      img.loading = "lazy"
      // The thumbnail has no reserved dimensions, so its own load can still
      // shift the card's height after the rest of this render already ran.
      img.addEventListener("load", () => this.repositionLookupCard())
      wrap.append(img)
    }

    const title = document.createElement("h3")
    title.className = "reader-lookup-wiki__title"
    title.textContent = data.title || this.lookupState?.word || ""
    wrap.append(title)

    if (data.extract) {
      const extract = document.createElement("p")
      extract.className = "reader-lookup-wiki__extract"
      extract.textContent = data.extract
      wrap.append(extract)
    } else {
      const empty = document.createElement("p")
      empty.className = "reader-empty-note"
      empty.textContent = "No article found."
      wrap.append(empty)
    }

    const pageUrl = data.content_urls?.desktop?.page
    if (pageUrl) {
      const link = document.createElement("a")
      link.className = "reader-lookup-wiki__link"
      link.href = pageUrl
      link.target = "_blank"
      link.rel = "noopener noreferrer"
      link.textContent = "Read on Wikipedia →"
      wrap.append(link)
    }

    this.lookupWikipediaPaneTarget.replaceChildren(wrap)
    this.repositionLookupCard()
  }

  renderLookupWikipediaNotFound() {
    if (!this.hasLookupWikipediaPaneTarget) return
    const p = document.createElement("p")
    p.className = "reader-empty-note"
    p.textContent = "No Wikipedia article found."
    this.lookupWikipediaPaneTarget.replaceChildren(p)
    this.repositionLookupCard()
  }

  renderLookupWikipediaError() {
    if (!this.hasLookupWikipediaPaneTarget) return
    const p = document.createElement("p")
    p.className = "reader-empty-note"
    p.textContent = "Couldn't load Wikipedia."
    this.lookupWikipediaPaneTarget.replaceChildren(p)
    this.repositionLookupCard()
  }

  // -- Annotations: loading, drawing, popover, drawer ----------------------

  async loadAnnotations() {
    if (!this.annotationsUrlValue) return
    try {
      const response = await fetch(this.annotationsUrlValue, { headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error(`fetch ${this.annotationsUrlValue} -> ${response.status}`)
      const rows = await response.json()
      this.annotations = rows
      this.annotationsById = new Map(rows.map((row) => [ row.id, row ]))
      this.annotationsByCfi = new Map(rows.filter((row) => row.cfi).map((row) => [ row.cfi, row ]))
      this.renderAnnotationsList()
      await this.drawAnnotations(rows)
      this.resolveKindleAnnotationsInBackground(rows)
    } catch (error) {
      console.error("[reader] failed to load annotations", error)
    }
  }

  async drawAnnotations(rows) {
    await Promise.all(rows.filter((row) => row.cfi).map((row) => this.drawAnnotationRow(row)))
  }

  async drawAnnotationRow(row) {
    if (!this.view || !row.cfi) return
    try {
      // Only `value` is read by addAnnotation() itself — `color`/`source`
      // ride along untouched to the 'draw-annotation' event below, which
      // is where the actual color/style choice happens.
      await this.view.addAnnotation({ value: row.cfi, color: row.color || "yellow", source: row.source })
    } catch (error) {
      console.error("[reader] failed to draw annotation", row.id, error)
    }
  }

  // A freshly-mounted section's overlayer only auto-redraws foliate-js's
  // own search-result markers (see View#createOverlayer in view.js) — not
  // our annotations. Worse, calling addAnnotation() synchronously from the
  // 'load' handler races the section's overlayer creation and silently
  // no-ops (the overlayer doesn't exist yet at that point in foliate-js's
  // own load sequence). 'create-overlay' fires once the overlayer for a
  // section genuinely exists, so redrawing everything then is both correct
  // and — since addAnnotation() is a no-op for any cfi that doesn't
  // resolve into the section that just mounted — cheap enough not to
  // bother filtering by section first.
  redrawAnnotations() {
    if (this.annotations.length) this.drawAnnotations(this.annotations)
  }

  onDrawAnnotation(event) {
    const { draw, annotation } = event.detail
    const hex = COLOR_HEX[annotation.color] || COLOR_HEX.yellow
    if (annotation.source === "web") draw(Overlayer.highlight, { color: hex })
    else draw(Overlayer.underline, { color: hex, width: 3 })
  }

  onShowAnnotation(event) {
    const { value, range } = event.detail
    const row = this.annotationsByCfi.get(value)
    if (!row) return
    this.openAnnotationPopover(row, range)
  }

  openAnnotationPopover(row, range) {
    if (!this.hasAnnotationPopoverTarget) return
    this.currentPopoverRow = row
    this.renderAnnotationPopoverBody(row)
    const rect = this.hostRectForRange(range)
    this.hideSelectionMenu()
    if (rect) this.positionFloating(this.annotationPopoverTarget, rect)
    this.annotationPopoverTarget.classList.add("is-open")
  }

  closeAnnotationPopover() {
    if (this.hasAnnotationPopoverTarget) this.annotationPopoverTarget.classList.remove("is-open")
    this.currentPopoverRow = null
  }

  isAnnotationPopoverOpen() {
    return this.hasAnnotationPopoverTarget && this.annotationPopoverTarget.classList.contains("is-open")
  }

  renderAnnotationPopoverBody(row) {
    if (!this.hasAnnotationPopoverBodyTarget) return
    this.annotationPopoverBodyTarget.replaceChildren(this.buildAnnotationPopoverContent(row))
  }

  // Built with DOM calls, not innerHTML — annotation content (highlighted
  // passages, notes) is book- and user-authored text, never trusted enough
  // to interpolate into markup.
  buildAnnotationPopoverContent(row) {
    const frag = document.createDocumentFragment()

    const badge = document.createElement("div")
    badge.className = "reader-annotation-popover__badge"
    badge.textContent = row.source === "web" ? "Folio Web" : (row.device_name || "Kindle")
    frag.append(badge)

    if (row.content) {
      const excerpt = document.createElement("p")
      excerpt.className = "reader-annotation-popover__excerpt"
      excerpt.textContent = row.content
      frag.append(excerpt)
    }

    if (row.note) {
      const note = document.createElement("p")
      note.className = "reader-annotation-popover__note"
      note.textContent = row.note
      frag.append(note)
    }

    // Editing/deleting is web-rows-only server-side (ReaderAnnotationsController
    // 403s #update/#destroy for any other source) — clippings rows only ever
    // get a badge + excerpt here, never actionable buttons.
    if (row.source === "web") {
      const colors = document.createElement("div")
      colors.className = "reader-annotation-popover__colors"
      for (const color of HIGHLIGHT_COLORS) {
        const dot = document.createElement("button")
        dot.type = "button"
        dot.className = `reader-selection-dot reader-selection-dot--${color}`
        if (row.color === color) dot.classList.add("is-active")
        dot.setAttribute("aria-label", `Change highlight color to ${color}`)
        dot.setAttribute("data-action", "click->reader#changeAnnotationColor")
        dot.dataset.readerColorParam = color
        colors.append(dot)
      }
      frag.append(colors)

      const actions = document.createElement("div")
      actions.className = "reader-annotation-popover__actions"

      const editNote = document.createElement("button")
      editNote.type = "button"
      editNote.className = "reader-icon-btn"
      editNote.textContent = row.note ? "Edit note" : "Add note"
      editNote.setAttribute("data-action", "click->reader#editAnnotationNote")
      actions.append(editNote)

      const del = document.createElement("button")
      del.type = "button"
      del.className = "btn btn--danger"
      del.textContent = "Delete"
      del.setAttribute("data-action", "click->reader#deleteCurrentAnnotation")
      actions.append(del)

      frag.append(actions)
    }

    return frag
  }

  async changeAnnotationColor(event) {
    const row = this.currentPopoverRow
    if (!row || row.source !== "web") return
    const color = event.params.color

    const updated = await this.patchAnnotation(row.id, { color })
    if (!updated) return
    this.upsertAnnotationState(updated)
    if (updated.cfi) {
      await this.view?.deleteAnnotation({ value: updated.cfi })
      await this.drawAnnotationRow(updated)
    }
    this.currentPopoverRow = updated
    this.renderAnnotationPopoverBody(updated)
    this.renderAnnotationsList()
  }

  editAnnotationNote() {
    const row = this.currentPopoverRow
    if (!row || row.source !== "web") return
    this.closeAnnotationPopover()
    this.openNoteSheetForEdit(row)
  }

  async deleteCurrentAnnotation() {
    const row = this.currentPopoverRow
    if (!row || row.source !== "web") return

    const ok = await this.destroyAnnotation(row.id)
    if (!ok) return
    if (row.cfi) await this.view?.deleteAnnotation({ value: row.cfi })
    this.removeAnnotationState(row)
    this.closeAnnotationPopover()
    this.renderAnnotationsList()
  }

  // -- Note sheet -----------------------------------------------------

  openNoteSheetForCreate(cfi, content) {
    if (!this.hasNoteSheetTarget) return
    this.pendingNoteContext = { mode: "create", cfi, content }
    if (this.hasNoteTextareaTarget) this.noteTextareaTarget.value = ""
    this.openPanel(this.noteSheetTarget)
    this.focusNoteTextarea()
  }

  openNoteSheetForEdit(row) {
    if (!this.hasNoteSheetTarget) return
    this.pendingNoteContext = { mode: "edit", annotationId: row.id }
    if (this.hasNoteTextareaTarget) this.noteTextareaTarget.value = row.note || ""
    this.openPanel(this.noteSheetTarget)
    this.focusNoteTextarea()
  }

  // Focusing while the sheet is still off-screen must not let the browser
  // scroll #reader-root (overflow:hidden but still focus-scrollable) — that
  // shift is never undone and misaligns every absolutely-positioned overlay.
  focusNoteTextarea() {
    if (!this.hasNoteTextareaTarget) return
    this.noteTextareaTarget.focus({ preventScroll: true })
    this.element.scrollTop = 0
    this.element.scrollLeft = 0
  }

  async saveNote() {
    const ctx = this.pendingNoteContext
    const noteText = this.hasNoteTextareaTarget ? this.noteTextareaTarget.value.trim() : ""
    this.closePanels() // also clears pendingNoteContext, so grab ctx first
    if (!ctx) return

    if (ctx.mode === "create") {
      const row = await this.createAnnotation({ kind: "note", cfi: ctx.cfi, content: ctx.content, note: noteText || null })
      if (!row) return
      this.upsertAnnotationState(row)
      await this.drawAnnotationRow(row)
    } else {
      const updated = await this.patchAnnotation(ctx.annotationId, { note: noteText || null })
      if (!updated) return
      this.upsertAnnotationState(updated)
    }
    this.renderAnnotationsList()
  }

  // -- Annotations drawer -----------------------------------------------

  openAnnotations() {
    this.renderAnnotationsList()
    this.openPanel(this.annotationsPanelTarget)
  }

  renderAnnotationsList() {
    if (!this.hasAnnotationsListTarget) return
    this.annotationsListTarget.replaceChildren()
    if (!this.annotations.length) {
      const empty = document.createElement("p")
      empty.className = "reader-empty-note"
      empty.textContent = "No highlights, notes or bookmarks yet."
      this.annotationsListTarget.append(empty)
      return
    }
    for (const row of this.annotations) this.annotationsListTarget.append(this.buildAnnotationListItem(row))
  }

  buildAnnotationListItem(row) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "reader-annotation-item"
    button.disabled = !row.cfi
    if (!row.cfi) button.classList.add("is-unresolved")
    if (row.cfi) {
      button.dataset.cfi = row.cfi
      button.setAttribute("data-action", "click->reader#goToAnnotation")
    }

    const chip = document.createElement("span")
    chip.className = "reader-annotation-item__chip"
    if (row.source === "web") {
      chip.classList.add(`reader-annotation-item__chip--${row.color || "yellow"}`)
    } else {
      chip.classList.add("reader-annotation-item__chip--kindle")
      chip.textContent = "K"
    }
    button.append(chip)

    const body = document.createElement("span")
    body.className = "reader-annotation-item__body"

    if (row.content) {
      const excerpt = document.createElement("span")
      excerpt.className = "reader-annotation-item__excerpt"
      excerpt.textContent = row.content
      body.append(excerpt)
    }
    if (row.note) {
      const note = document.createElement("span")
      note.className = "reader-annotation-item__note"
      note.textContent = row.note
      body.append(note)
    }

    const meta = document.createElement("span")
    meta.className = "reader-annotation-item__meta"
    const sourceLabel = row.source === "web" ? "Web" : (row.device_name || "Kindle")
    meta.textContent = [ sourceLabel, this.formatAnnotationTimestamp(row.added_at) ].filter(Boolean).join(" · ")
    body.append(meta)

    button.append(body)
    return button
  }

  goToAnnotation(event) {
    const cfi = event.currentTarget.dataset.cfi
    if (cfi) this.view?.goTo(cfi)
    this.closePanels()
  }

  formatAnnotationTimestamp(value) {
    if (!value) return ""
    try {
      return new Date(value).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" })
    } catch (error) {
      return ""
    }
  }

  // -- Kindle clippings without a CFI: background best-effort locate -----
  //
  // Clippings-imported highlights only carry the passage text (no CFI).
  // We locate at most MAX_LAZY_LOCATE_ROWS of them per book-open, one at a
  // time, by searching the whole book's text for a unique occurrence of
  // the passage. Deliberately doesn't use view.search(): that method
  // clears and overwrites the single shared search-result state the
  // user-facing search panel also uses (see View#search/#clearSearch in
  // view.js), which would stomp an in-progress user search. Instead this
  // drives foliate-js's lower-level search.js/text-walker.js matcher
  // directly against documents it creates and discards itself.
  async resolveKindleAnnotationsInBackground(rows) {
    const targets = rows
      .filter((row) => row.source !== "web" && row.kind === "highlight" && !row.cfi && row.content?.trim())
      .slice(0, MAX_LAZY_LOCATE_ROWS)
    if (!targets.length || !this.view) return

    const token = this.lazyLocateToken
    let matcher
    try {
      matcher = await this.loadSearchMatcher()
    } catch (error) {
      console.error("[reader] failed to load search plumbing for background locate", error)
      return
    }

    const docCache = new Map()
    for (const row of targets) {
      // Aborted by disconnect()/retry() bumping the token — leaving the
      // reader or reopening the book mid-pass.
      if (token !== this.lazyLocateToken || !this.view) return
      await this.resolveOneKindleAnnotation(row, matcher, docCache)
    }
  }

  async resolveOneKindleAnnotation(row, matcher, docCache) {
    try {
      const hit = await this.findUniqueMatchInBook(matcher, row.content, docCache)
      if (!hit) return // no match, or more than one — not unique enough; skip silently
      const updated = await this.patchAnnotationLocate(row.id, hit.cfi)
      if (!updated || !updated.cfi) return
      this.upsertAnnotationState(updated)
      await this.drawAnnotationRow(updated)
      this.renderAnnotationsList()
    } catch (error) {
      console.error("[reader] failed to locate clipping", row.id, error)
    }
  }

  // search.js/text-walker.js aren't pinned in importmap.rb (only the four
  // modules the reader imports directly are) — loaded dynamically here,
  // shared by both callers below that need "search hit -> cfi" without
  // going through view.search() (which clears/overwrites the single
  // shared search-panel state — see the comment above
  // resolveKindleAnnotationsInBackground()).
  async loadSearchMatcher() {
    const [ searchModule, textWalkerModule ] = await Promise.all([
      import(`${FOLIATE_JS_BASE}/search.js`),
      import(`${FOLIATE_JS_BASE}/text-walker.js`)
    ])
    return searchModule.searchMatcher(textWalkerModule.textWalker, {})
  }

  // Shared section-by-section walk (each section's document created and
  // cached on first visit) yielding every {index, range} match — the only
  // difference between findUniqueMatchInBook (used to auto-locate a
  // Kindle clipping, where a non-unique match isn't trustworthy enough to
  // silently attach) and findFirstMatchInBook (used to jump to a Kindle
  // sync position, where any hit is good enough) is how many of these
  // they consume.
  async *iterateBookMatches(matcher, query, docCache) {
    const sections = this.view?.book?.sections
    if (!sections) return

    for (let index = 0; index < sections.length; index++) {
      const section = sections[index]
      if (!section.createDocument) continue
      let doc = docCache.get(index)
      if (doc === undefined) {
        doc = await section.createDocument()
        docCache.set(index, doc)
      }
      if (!doc) continue
      for (const { range } of matcher(doc, query)) yield { index, range }
    }
  }

  async findUniqueMatchInBook(matcher, query, docCache) {
    let found = null
    for await (const hit of this.iterateBookMatches(matcher, query, docCache)) {
      if (found) return null // a second occurrence anywhere — not unique
      found = hit
    }
    if (!found) return null
    return { cfi: this.view.getCFI(found.index, found.range) }
  }

  async findFirstMatchInBook(matcher, query, docCache) {
    for await (const hit of this.iterateBookMatches(matcher, query, docCache)) {
      return { cfi: this.view.getCFI(hit.index, hit.range) }
    }
    return null
  }

  // -- Annotation CRUD (fetch helpers) -----------------------------------

  upsertAnnotationState(row) {
    this.annotationsById.set(row.id, row)
    if (row.cfi) this.annotationsByCfi.set(row.cfi, row)
    const index = this.annotations.findIndex((a) => a.id === row.id)
    if (index === -1) this.annotations.push(row)
    else this.annotations[index] = row
  }

  removeAnnotationState(row) {
    this.annotationsById.delete(row.id)
    if (row.cfi) this.annotationsByCfi.delete(row.cfi)
    this.annotations = this.annotations.filter((a) => a.id !== row.id)
  }

  createAnnotation(payload) {
    return this.mutateAnnotation(this.annotationsUrlValue, "POST", payload)
  }

  patchAnnotation(id, payload) {
    return this.mutateAnnotation(`${this.annotationsUrlValue}/${id}`, "PATCH", payload)
  }

  patchAnnotationLocate(id, cfi) {
    return this.mutateAnnotation(`${this.annotationsUrlValue}/${id}/locate`, "PATCH", { cfi })
  }

  async destroyAnnotation(id) {
    try {
      const response = await fetch(`${this.annotationsUrlValue}/${id}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": this.csrfTokenValue, "Accept": "application/json" }
      })
      return response.ok
    } catch (error) {
      console.error("[reader] failed to delete annotation", id, error)
      return false
    }
  }

  async mutateAnnotation(url, method, payload) {
    try {
      const response = await fetch(url, {
        method,
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfTokenValue,
          "Accept": "application/json"
        },
        body: JSON.stringify(payload)
      })
      if (!response.ok) {
        console.error(`[reader] annotation request failed: ${method} ${url} -> ${response.status}`)
        return null
      }
      return await response.json()
    } catch (error) {
      console.error(`[reader] annotation request errored: ${method} ${url}`, error)
      return null
    }
  }

  // -- Settings -----------------------------------------------------------

  openSettings() {
    this.renderSettingsUI()
    this.openPanel(this.settingsPanelTarget)
  }

  loadSettings() {
    try {
      const raw = window.localStorage.getItem(SETTINGS_KEY)
      const stored = raw ? JSON.parse(raw) : {}
      return { ...DEFAULT_SETTINGS, ...stored }
    } catch (error) {
      // Safari private mode (and similar) can throw on localStorage access.
      console.error("[reader] failed to read settings", error)
      return { ...DEFAULT_SETTINGS }
    }
  }

  saveSettings() {
    try {
      window.localStorage.setItem(SETTINGS_KEY, JSON.stringify(this.settings))
    } catch (error) {
      console.error("[reader] failed to save settings", error)
    }
  }

  updateSetting(key, value) {
    this.settings = { ...this.settings, [key]: value }
    this.saveSettings()
    if (key === "theme") this.applyChromeTheme()
    if (key === "flow") this.applyFlow()
    this.applyContentStyles()
    this.renderSettingsUI()
  }

  increaseFontSize() {
    this.updateSetting("fontSize", Math.min(200, this.settings.fontSize + 10))
  }

  decreaseFontSize() {
    this.updateSetting("fontSize", Math.max(70, this.settings.fontSize - 10))
  }

  onLineHeightInput(event) {
    this.updateSetting("lineHeight", parseFloat(event.target.value))
  }

  onMarginInput(event) {
    this.updateSetting("margin", parseInt(event.target.value, 10))
  }

  setTheme(event) {
    this.updateSetting("theme", event.params.theme)
  }

  setFlow(event) {
    this.updateSetting("flow", event.params.flow)
  }

  renderSettingsUI() {
    if (this.hasFontSizeReadoutTarget) this.fontSizeReadoutTarget.textContent = `${this.settings.fontSize}%`
    if (this.hasLineHeightSliderTarget) this.lineHeightSliderTarget.value = this.settings.lineHeight
    if (this.hasLineHeightReadoutTarget) this.lineHeightReadoutTarget.textContent = this.settings.lineHeight.toFixed(1)
    if (this.hasMarginSliderTarget) this.marginSliderTarget.value = this.settings.margin
    if (this.hasMarginReadoutTarget) this.marginReadoutTarget.textContent = `${this.settings.margin}px`
    this.themeButtonTargets.forEach((btn) =>
      btn.classList.toggle("is-active", btn.dataset.readerThemeParam === this.settings.theme))
    this.flowButtonTargets.forEach((btn) =>
      btn.classList.toggle("is-active", btn.dataset.readerFlowParam === this.settings.flow))
  }

  // Chrome (our own page) can use CSS custom properties; the book's
  // content (a separate document via renderer.setStyles) cannot see them.
  applyChromeTheme() {
    document.body.dataset.theme = this.settings.theme
  }

  applyFlow() {
    this.view?.renderer?.setAttribute("flow", this.settings.flow === "scrolled" ? "scrolled" : "paginated")
  }

  applyContentStyles() {
    this.view?.renderer?.setStyles?.(this.buildContentCss())
  }

  buildContentCss() {
    const { fontSize, lineHeight, margin } = this.settings
    const palette = THEMES[this.settings.theme] ?? THEMES.light
    // !important: the book's own stylesheet frequently sets these same
    // properties on html/body/a, at equal-or-higher specificity.
    return `
      html, body { background: ${palette.background} !important; color: ${palette.color} !important; }
      body { font-size: ${fontSize}% !important; line-height: ${lineHeight} !important; margin: ${margin}px !important; }
      a, a:link, a:visited { color: ${palette.link} !important; }
    `
  }

  // -- Fullscreen -----------------------------------------------------------

  toggleFullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else {
      this.element.requestFullscreen?.().catch((error) => console.error("[reader] fullscreen failed", error))
    }
  }

  onFullscreenChange() {
    this.element.classList.toggle("reader-fullscreen", document.fullscreenElement === this.element)
  }

  // -- Position / progress -----------------------------------------------

  onProgressInput(event) {
    this.sliderDragging = true
    const percent = Math.round(Number(event.target.value) * 100)
    if (this.hasReadoutTarget) this.readoutTarget.textContent = `${percent}%`
  }

  onProgressChange(event) {
    this.sliderDragging = false
    this.view?.goToFraction(Number(event.target.value))
  }

  onRelocate(event) {
    this.hideSelectionMenu()
    this.closeAnnotationPopover()
    this.closeLookupCard()

    const { cfi, fraction, tocItem, range } = event.detail
    const percent = Math.round((fraction ?? 0) * 100)
    this.currentFraction = fraction ?? 0

    this.updateReadout(percent, fraction ?? 0, tocItem)
    this.updateTocHighlight(tocItem)
    if (this.hasProgressSliderTarget && !this.sliderDragging) this.progressSliderTarget.value = fraction ?? 0

    this.pendingPosition = { cfi, fraction, percent, context: this.buildPositionContext(range) }
    if (this.saveTimer) clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => this.flushPosition(), SAVE_DEBOUNCE_MS)
  }

  updateReadout(percent, fraction, tocItem) {
    if (!this.hasReadoutTarget) return

    if (this.hasTextLengthValue && this.textLengthValue > 0) {
      const total = Math.floor(this.textLengthValue / BYTES_PER_LOCATION) + 1
      const current = Math.floor((fraction * this.textLengthValue) / BYTES_PER_LOCATION) + 1
      this.readoutTarget.textContent = `${percent}% · Loc ${current} of ${total}`
    } else {
      this.readoutTarget.textContent = tocItem?.label ? `${percent}% · ${tocItem.label}` : `${percent}%`
    }
  }

  async flushPosition() {
    const position = this.pendingPosition
    this.pendingPosition = null
    if (!position) return

    // context {exact, before, after} — captured at relocate time by
    // buildPositionContext() — is what lets the server resolve this
    // position back to a raw byte offset in the Kindle's own MOBI text
    // stream for write-back (Reader::Anchor.locate, driven by
    // KindleWritebackJob); an empty context just means "no write-back
    // this time" server-side (ReaderController#update_position's
    // "no_context" outcome), never an error here.
    const body = { cfi: position.cfi, fraction: position.fraction, percent: position.percent, context: position.context || {} }
    try {
      const data = await this.putPosition(body)
      this.handleWritebackDecision(data?.writeback, body)
    } catch (error) {
      console.error("[reader] failed to save position", error)
    }
  }

  // -- Kindle sync ----------------------------------------------------------
  //
  // Three independent pieces, all funneling through goToKindlePosition()
  // for "jump to where the Kindle is": (1) open-time — once the book has
  // opened, a one-shot GET /state either surfaces a dismissible top banner
  // ("Kindle is further ahead — Go?") or, if this is the very first time
  // this book has been opened on the web (no saved web position at all),
  // silently jumps there; (2) a 30s live poll while the tab is visible,
  // surfacing a non-modal auto-dismissing toast when the Kindle's own
  // last-synced reading state has moved further than the web position
  // since the poll started; (3) the "skipped_backward" write-back outcome
  // (a *web* position landing behind the Kindle's, handled by
  // handleWritebackDecision(), below) offering to move the Kindle back —
  // the opposite direction from (1)/(2), but the same banner UI.

  async fetchReaderState() {
    if (!this.hasStateUrlValue) return null
    try {
      const response = await fetch(this.stateUrlValue, { headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error(`fetch ${this.stateUrlValue} -> ${response.status}`)
      return await response.json()
    } catch (error) {
      console.error("[reader] failed to fetch reader state", error)
      return null
    }
  }

  async syncWithKindleOnOpen() {
    const state = await this.fetchReaderState()
    if (!state) return
    this.rememberKindleMtime(state.kindle)
    const kindle = state.kindle
    if (!kindle) return

    if (state.web == null) {
      // No web position at all — this book has only ever been read on
      // the Kindle, so there's nothing to compare against; just go there.
      await this.goToKindlePosition(kindle)
      return
    }
    if (typeof kindle.percent !== "number") return

    const webPercent = state.web.percent ?? 0
    if (kindle.percent > webPercent + SYNC_PERCENT_SLACK) {
      this.showSyncBanner({
        kind: "open-sync",
        message: `${kindle.device_name || "Kindle"} is at ${Math.round(kindle.percent)}% — Go there?`,
        actionLabel: "Go",
        onAction: () => this.goToKindlePosition(kindle)
      })
    }
  }

  // -- Live poll: GET /state every 30s while the tab is visible -----------

  armLivePoll() {
    this.clearLivePoll()
    if (document.visibilityState !== "visible" || !this.view) return
    this.pollFailures = 0
    this.pollTimer = setInterval(() => this.pollKindleState(), LIVE_POLL_INTERVAL_MS)
  }

  clearLivePoll() {
    if (this.pollTimer) clearInterval(this.pollTimer)
    this.pollTimer = null
  }

  handleVisibilityChange() {
    if (document.visibilityState === "visible") {
      this.armLivePoll()
      return
    }
    this.clearLivePoll()
    // The same reliable-fallback reasoning as the pagehide listener in
    // connect() — visibilitychange -> hidden fires for tab switches, tab
    // close, and OS backgrounding alike (including on iOS Safari, where
    // beforeunload/pagehide aren't dependable), so this is the one place
    // guaranteed to catch a pending debounced save before Stimulus's own
    // disconnect() might never run. No-op via flushPosition()'s own guard
    // when there's nothing pending.
    this.flushPosition()
  }

  async pollKindleState() {
    // Unobtrusive: skip this tick entirely (rather than showing something
    // over it) while any drawer/sheet/selection/annotation/lookup UI is
    // up — the next tick, 30s later, re-evaluates from scratch.
    if (this.hasOpenPanel() || this.isSelectionMenuOpen() || this.isLookupCardOpen() || this.isAnnotationPopoverOpen()) return

    const state = await this.fetchReaderState()
    if (!state) {
      this.pollFailures += 1
      if (this.pollFailures >= LIVE_POLL_MAX_FAILURES) this.clearLivePoll()
      return
    }
    this.pollFailures = 0

    const kindle = state.kindle
    if (!kindle || typeof kindle.percent !== "number") return
    if (!this.rememberKindleMtime(kindle)) return // not newer than the mtime already considered

    const currentPercent = this.currentFraction * 100
    if (kindle.percent > currentPercent + SYNC_PERCENT_SLACK) {
      this.showSyncToast({
        message: `${kindle.device_name || "Kindle"} kept reading — now at ${Math.round(kindle.percent)}%`,
        actionLabel: "Go",
        onAction: () => this.goToKindlePosition(kindle)
      })
    }
  }

  // Advances this.kindleMtimeBaseline to kindle.content_mtime and returns
  // true, but only if it's actually newer than what's already been
  // considered (open-time sync's own fetch counts as the first "seen"
  // value) — false means "nothing new, don't re-toast the same mtime".
  rememberKindleMtime(kindle) {
    if (!kindle?.content_mtime) return false
    const mtime = Date.parse(kindle.content_mtime)
    if (Number.isNaN(mtime)) return false
    if (this.kindleMtimeBaseline != null && mtime <= this.kindleMtimeBaseline) return false
    this.kindleMtimeBaseline = mtime
    return true
  }

  // Shared "go to where the Kindle is" resolution for the open-time
  // banner, the live-poll toast, and (from the opposite direction — see
  // handleWritebackDecision()) nothing yet, since moving the Kindle back
  // doesn't move the web view. Prefers a text search hit for the synced
  // position's own snippet (precise, survives re-pagination/EPUB-vs-MOBI
  // offset differences) and falls back to the coarser percent when there's
  // no snippet or it doesn't resolve to a unique-enough hit. Either way,
  // the resulting 'relocate' event feeds the normal debounced-save flow
  // (onRelocate/flushPosition, above), persisting the jump like any other
  // navigation.
  async goToKindlePosition(kindle) {
    if (!this.view || !kindle) return
    try {
      const cfi = kindle.snippet?.exact ? await this.locateSnippetCfi(kindle.snippet.exact) : null
      if (cfi) await this.view.goTo(cfi)
      else if (typeof kindle.percent === "number") await this.view.goToFraction(kindle.percent / 100)
    } catch (error) {
      console.error("[reader] failed to go to kindle position", error)
    }
  }

  async locateSnippetCfi(snippetText) {
    if (!snippetText || !this.view) return null
    try {
      const matcher = await this.loadSearchMatcher()
      const hit = await this.findFirstMatchInBook(matcher, snippetText, new Map())
      return hit?.cfi || null
    } catch (error) {
      console.error("[reader] failed to locate kindle snippet", error)
      return null
    }
  }

  // -- Sync banner (top, dismissible) --------------------------------------

  showSyncBanner({ kind, message, actionLabel, onAction }) {
    if (!this.hasSyncBannerTarget) return
    this.syncBannerTarget.replaceChildren()
    this.syncBannerTarget.dataset.syncBannerKind = kind || ""

    const text = document.createElement("span")
    text.className = "reader-sync-banner__text"
    text.textContent = message
    this.syncBannerTarget.append(text)

    if (actionLabel && onAction) {
      const action = document.createElement("button")
      action.type = "button"
      action.className = "btn btn--primary reader-sync-banner__action"
      action.textContent = actionLabel
      action.addEventListener("click", () => {
        this.dismissSyncBanner(kind)
        onAction()
      })
      this.syncBannerTarget.append(action)
    }

    const dismiss = document.createElement("button")
    dismiss.type = "button"
    dismiss.className = "reader-icon-btn reader-sync-banner__dismiss"
    dismiss.setAttribute("aria-label", "Dismiss")
    dismiss.textContent = "✕"
    dismiss.addEventListener("click", () => this.dismissSyncBanner(kind))
    this.syncBannerTarget.append(dismiss)

    this.syncBannerTarget.classList.add("is-open")
  }

  // User-initiated dismiss or action (as opposed to closeSyncBanner(),
  // which is also called incidentally e.g. when a drawer opens over it) —
  // for the "backward" kind (see handleWritebackDecision()) this is what
  // makes the prompt "one-time-per-session": once acted on or dismissed,
  // it won't ask again for the rest of this page's lifetime.
  dismissSyncBanner(kind) {
    if (kind === "backward") this.backwardPromptDismissed = true
    this.closeSyncBanner()
  }

  closeSyncBanner() {
    if (this.hasSyncBannerTarget) this.syncBannerTarget.classList.remove("is-open")
  }

  isSyncBannerOpen() {
    return this.hasSyncBannerTarget && this.syncBannerTarget.classList.contains("is-open")
  }

  // -- Sync toast (non-modal, auto-dismissing) -----------------------------

  showSyncToast({ message, actionLabel, onAction }) {
    if (!this.hasSyncToastTarget) return
    this.syncToastTarget.replaceChildren()

    const text = document.createElement("span")
    text.className = "reader-sync-toast__text"
    text.textContent = message
    this.syncToastTarget.append(text)

    if (actionLabel && onAction) {
      const action = document.createElement("button")
      action.type = "button"
      action.className = "btn btn--primary reader-sync-toast__action"
      action.textContent = actionLabel
      action.addEventListener("click", () => {
        this.closeSyncToast()
        onAction()
      })
      this.syncToastTarget.append(action)
    }

    const dismiss = document.createElement("button")
    dismiss.type = "button"
    dismiss.className = "reader-icon-btn reader-sync-toast__dismiss"
    dismiss.setAttribute("aria-label", "Dismiss")
    dismiss.textContent = "✕"
    dismiss.addEventListener("click", () => this.closeSyncToast())
    this.syncToastTarget.append(dismiss)

    this.syncToastTarget.classList.add("is-open")
    if (this.syncToastTimer) clearTimeout(this.syncToastTimer)
    this.syncToastTimer = setTimeout(() => this.closeSyncToast(), SYNC_TOAST_AUTO_DISMISS_MS)
  }

  closeSyncToast() {
    if (this.syncToastTimer) clearTimeout(this.syncToastTimer)
    this.syncToastTimer = null
    if (this.hasSyncToastTarget) this.syncToastTarget.classList.remove("is-open")
  }

  isSyncToastOpen() {
    return this.hasSyncToastTarget && this.syncToastTarget.classList.contains("is-open")
  }

  // -- Write-back decision (opposite direction: web position behind the
  //    Kindle's own) ---------------------------------------------------

  // {"writeback": "disabled"|"no_context"|"skipped_backward"|"enqueued"} —
  // see ReaderController#update_position. Only "skipped_backward" needs a
  // client reaction: the server declined to push this web position to the
  // Kindle because it's further behind than the Kindle's own last-synced
  // position, so offer to override with confirm_backward.
  handleWritebackDecision(decision, payload) {
    if (decision !== "skipped_backward") {
      // A "backward" banner shown by an earlier flush is now stale: either
      // this flush caught up (decision is "enqueued") or write-back no
      // longer applies at all. Its onAction closure still captures that
      // earlier flush's payload, so leaving the banner up risks the user
      // confirming a move with a stale cfi/fraction/context -- overwriting
      // the current, further-along saved position (and regressing the
      // physical Kindle to match it) on tap.
      if (this.hasSyncBannerTarget && this.syncBannerTarget.dataset.syncBannerKind === "backward") {
        this.closeSyncBanner()
      }
      return
    }
    if (this.backwardPromptDismissed) return
    this.showSyncBanner({
      kind: "backward",
      message: "Kindle is further ahead — move it back to here?",
      actionLabel: "Move Kindle back",
      onAction: () => this.confirmMoveKindleBack(payload)
    })
  }

  async confirmMoveKindleBack(payload) {
    try {
      await this.putPosition({ ...payload, confirm_backward: true })
    } catch (error) {
      console.error("[reader] failed to confirm move-kindle-back", error)
    }
  }

  async putPosition(body) {
    const response = await fetch(this.positionUrlValue, {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfTokenValue,
        "Accept": "application/json"
      },
      body: JSON.stringify(body),
      keepalive: true
    })
    if (!response.ok) throw new Error(`PUT ${this.positionUrlValue} -> ${response.status}`)
    return response.json()
  }

  // -- Position context capture --------------------------------------------
  //
  // context.exact/before/after ride along on every debounced position save
  // (flushPosition(), above) as plain rendered-text snippets anchored at
  // the relocate event's own `range` — foliate-js's "visible range", i.e.
  // this page's/viewport's start (see paginator.js's #getVisibleRange).
  // Server-side, Reader::Anchor.locate() re-normalizes whatever we send
  // (strip tags, decode entities, collapse whitespace) to resolve a raw
  // byte offset in the Kindle's own MOBI text stream for write-back (see
  // KindleWritebackJob) — so this only needs a best-effort, *bounded* walk
  // of the rendered DOM text near that point, not anything byte-precise.
  buildPositionContext(range) {
    if (!range?.startContainer) return {}
    try {
      const doc = range.startContainer.ownerDocument
      const root = doc?.body || doc?.documentElement
      if (!root) return {}

      const exact = this.walkTextForward(root, range.startContainer, range.startOffset, CONTEXT_EXACT_CHARS)
      const exactText = this.collapseWhitespace(exact.text).trim()
      if (!exactText) return {}

      const before = this.walkTextBackward(root, range.startContainer, range.startOffset, CONTEXT_BEFORE_CHARS)
      const after = this.walkTextForward(root, exact.endContainer, exact.endOffset, CONTEXT_AFTER_CHARS)

      return {
        exact: exactText,
        before: this.collapseWhitespace(before.text).trim(),
        after: this.collapseWhitespace(after.text).trim()
      }
    } catch (error) {
      console.error("[reader] failed to capture position context", error)
      return {}
    }
  }

  // Collects rendered text forward from (container, offset), stopping as
  // soon as maxChars (+ some whitespace-collapsing slack) is reached —
  // bounded, so this stays cheap even on relocate events that fire
  // rapidly during a scroll. Returns where it stopped (endContainer/
  // endOffset) so a caller can chain a second walk onward from there (see
  // the "after" snippet in buildPositionContext(), above). `container` may
  // be a text node (the common case — foliate-js's own visible-range
  // start is usually bisected into one) or an element (offset always 0
  // there — see getVisibleRange() in paginator.js), in which case this
  // starts from the first text node inside/after it.
  walkTextForward(root, container, offset, maxChars) {
    const doc = root.ownerDocument || root
    const budget = maxChars + CONTEXT_WALK_SLACK
    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT)
    walker.currentNode = container
    let node = container.nodeType === Node.TEXT_NODE ? container : walker.nextNode()

    let text = ""
    let endContainer = container
    let endOffset = offset

    while (node && text.length < budget) {
      const value = node.nodeValue || ""
      const startInNode = node === container ? offset : 0
      const remaining = budget - text.length
      const slice = value.slice(startInNode, startInNode + remaining)
      text += slice
      endContainer = node
      endOffset = startInNode + slice.length
      node = walker.nextNode()
    }

    return { text: text.slice(0, budget), endContainer, endOffset }
  }

  // Same idea, backward — collects rendered text preceding (container,
  // offset), keeping only the tail (the part closest to that point) once
  // the budget is met.
  walkTextBackward(root, container, offset, maxChars) {
    const doc = root.ownerDocument || root
    const budget = maxChars + CONTEXT_WALK_SLACK
    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT)
    walker.currentNode = container
    let node = container.nodeType === Node.TEXT_NODE ? container : walker.previousNode()

    let text = ""
    while (node && text.length < budget) {
      const value = node.nodeValue || ""
      const endInNode = node === container ? offset : value.length
      const remaining = budget - text.length
      const start = Math.max(0, endInNode - remaining)
      text = value.slice(start, endInNode) + text
      node = walker.previousNode()
    }

    return { text: text.slice(-budget) }
  }

  collapseWhitespace(text) {
    return text.replace(/\s+/g, " ")
  }

  // -- Loading / error states ----------------------------------------------

  showLoading() {
    if (this.hasLoadingTarget) this.loadingTarget.hidden = false
  }

  hideLoading() {
    if (this.hasLoadingTarget) this.loadingTarget.hidden = true
  }

  // Built with DOM calls (not innerHTML/template strings) since book- and
  // server-controlled text (titles, TOC labels, search excerpts) is never
  // trusted enough to interpolate into markup.
  showError() {
    this.hideLoading()
    this.viewportTarget.replaceChildren()
    const wrap = document.createElement("div")
    wrap.className = "reader-empty"
    const message = document.createElement("p")
    message.textContent = this.formatValue === "pdf"
      ? "This file couldn't be opened for reading. PDF reading isn't fully supported yet."
      : "This file couldn't be opened for reading."
    const retry = document.createElement("button")
    retry.type = "button"
    retry.className = "btn btn--quiet"
    retry.textContent = "Try again"
    retry.addEventListener("click", () => this.retry())
    wrap.append(message, retry)
    this.viewportTarget.append(wrap)
  }
}
