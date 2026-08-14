const pdfjsPath = path => new URL(`vendor/pdfjs/${path}`, import.meta.url).toString()

import './vendor/pdfjs/pdf.mjs'
const pdfjsLib = globalThis.pdfjsLib
pdfjsLib.GlobalWorkerOptions.workerSrc = pdfjsPath('pdf.worker.mjs')

const fetchText = async url => await (await fetch(url)).text()

// https://raw.githubusercontent.com/mozilla/pdf.js/refs/tags/v5.5.207/web/text_layer_builder.css
const textLayerBuilderCSS = await fetchText(pdfjsPath('text_layer_builder.css'))

// https://raw.githubusercontent.com/mozilla/pdf.js/refs/tags/v5.5.207/web/annotation_layer_builder.css
const annotationLayerBuilderCSS = await fetchText(pdfjsPath('annotation_layer_builder.css'))

// Caps the raster resolution a single `page.render()` call is allowed to
// ask for. `zoom * devicePixelRatio` is unbounded — a reader pinch-zooming
// into a large scanned page (or just a high-DPR display) can ask pdf.js to
// allocate a canvas many times the page's own pixel dimensions, which
// browsers either refuse to allocate or take a very long time to
// rasterize. Clamped scale preserves aspect ratio; the caller compensates
// with a larger CSS scale-up so the on-screen box size is unaffected —
// only extreme zoom gets a softer image instead of an OOM/hang.
const MAX_CANVAS_PIXELS = 16 * 1_000_000 // ~16 megapixels
const MAX_CANVAS_DIMENSION = 4096 // px, matches common GPU texture-size limits

const clampRenderScale = (viewport1x, requestedScale) => {
    const width = viewport1x.width * requestedScale
    const height = viewport1x.height * requestedScale
    if (!(width > 0) || !(height > 0)) return requestedScale
    const pixelBudgetFactor = Math.sqrt(MAX_CANVAS_PIXELS / (width * height))
    const dimensionFactor = MAX_CANVAS_DIMENSION / Math.max(width, height)
    const factor = Math.min(1, pixelBudgetFactor, dimensionFactor)
    return factor < 1 ? requestedScale * factor : requestedScale
}

// Renders a page's placeholder for when `page.render()` itself rejects
// (e.g. a JPXDecode/JBIG2Decode image the vendored wasm codecs can't
// decode) instead of leaving a blank canvas with no visible explanation.
const makeRenderErrorPlaceholder = (doc, pageNumber, viewport) => {
    const placeholder = doc.createElement('div')
    placeholder.className = 'pdf-render-error'
    Object.assign(placeholder.style, {
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: `${viewport.width}px`,
        height: `${viewport.height}px`,
        boxSizing: 'border-box',
        padding: '1em',
        textAlign: 'center',
        fontFamily: 'sans-serif',
        fontSize: '14px',
        color: '#900',
        background: '#fee',
        border: '1px solid #900',
    })
    placeholder.textContent = pageNumber
        ? `Page ${pageNumber} could not be displayed`
        : 'This page could not be displayed'
    return placeholder
}

const render = async (page, doc, zoom) => {
    const viewport1x = page.getViewport({ scale: 1 })
    const scale = clampRenderScale(viewport1x, zoom * devicePixelRatio)
    // normally `zoom / scale` collapses to `1 / devicePixelRatio`; it only
    // differs when clampRenderScale() above had to shrink the raster size,
    // in which case the extra CSS scale-up keeps the on-screen box size
    // matching what fixed-layout.js laid out for this frame
    doc.documentElement.style.transform = `scale(${zoom / scale})`
    doc.documentElement.style.transformOrigin = 'top left'
    doc.documentElement.style.setProperty('--scale-factor', scale)
    const viewport = page.getViewport({ scale })

    // the canvas must be in the `PDFDocument`'s `ownerDocument`
    // (`globalThis.document` by default); that's where the fonts are loaded
    const canvas = document.createElement('canvas')
    canvas.height = viewport.height
    canvas.width = viewport.width
    const canvasContext = canvas.getContext('2d')
    try {
        await page.render({ canvasContext, viewport }).promise
    } catch (error) {
        // isolated per-page failure (e.g. an undecodable image on one page
        // of an otherwise fine book): show *something* instead of a blank
        // canvas, but don't take the whole book down over it — the caller
        // (fixed-layout.js) only awaits this for the very first frame shown
        // on open, where section.load()'s own eager render probe (see
        // makePDF() below) already surfaces a hard failure earlier.
        console.error('[pdf.js] page render failed', error)
        doc.querySelector('#canvas').replaceChildren(
            makeRenderErrorPlaceholder(doc, page.pageNumber, viewport))
        return
    }
    doc.querySelector('#canvas').replaceChildren(doc.adoptNode(canvas))

    const container = doc.querySelector('.textLayer')
    const textLayer = new pdfjsLib.TextLayer({
        textContentSource: await page.streamTextContent(),
        container, viewport,
    })
    await textLayer.render()

    // hide "offscreen" canvases appended to docuemnt when rendering text layer
    // https://github.com/mozilla/pdf.js/blob/642b9a5ae67ef642b9a8808fd9efd447e8c350e2/web/pdf_viewer.css#L51-L58
    for (const canvas of document.querySelectorAll('.hiddenCanvasElement'))
        Object.assign(canvas.style, {
            position: 'absolute',
            top: '0',
            left: '0',
            width: '0',
            height: '0',
            display: 'none',
        })

    // fix text selection
    // https://github.com/mozilla/pdf.js/blob/642b9a5ae67ef642b9a8808fd9efd447e8c350e2/web/text_layer_builder.js#L105-L107
    const endOfContent = document.createElement('div')
    endOfContent.className = 'endOfContent'
    container.append(endOfContent)
    // TODO: this only works in Firefox; see https://github.com/mozilla/pdf.js/pull/17923
    container.onpointerdown = () => container.classList.add('selecting')
    container.onpointerup = () => container.classList.remove('selecting')

    const div = doc.querySelector('.annotationLayer')
    const linkService = {
        goToDestination: () => {},
        getDestinationHash: dest => JSON.stringify(dest),
        addLinkAttributes: (link, url) => link.href = url,
    }
    await new pdfjsLib.AnnotationLayer({ page, viewport, div, linkService })
        .render({ annotations: await page.getAnnotations() })
}

const renderPage = async (page, probeState, getImageBlob) => {
    const viewport = page.getViewport({ scale: 1 })
    if (getImageBlob) {
        const canvas = document.createElement('canvas')
        canvas.height = viewport.height
        canvas.width = viewport.width
        const canvasContext = canvas.getContext('2d')
        await page.render({ canvasContext, viewport }).promise
        return new Promise(resolve => canvas.toBlob(resolve))
    }

    // Eagerly decode+render the FIRST loaded page once, at scale 1, before
    // building its section's iframe shell. The pixels themselves are thrown
    // away — the real render happens later, at the actual on-screen scale,
    // via `onZoom` below — but this is the only place a *hard* codec
    // failure (e.g. a JPXDecode/JBIG2Decode image the vendored wasm can't
    // decode) can reject `section.load()` itself, which the very first
    // navigation performed by `view.init()` awaits, so it propagates up to
    // reader_controller.js's `open()` try/catch instead of resolving into a
    // blank shell. Only the first load of each book probes: `probeState`
    // is a fresh `{ probed: false }` object created per `makePDF()` call
    // and passed in here, NOT a property cached on the `renderPage`
    // function itself — Turbo Drive keeps this module's JS realm alive
    // across page visits, so a function-level latch would silently skip
    // the probe for every book opened after the first one in a tab. A
    // broken codec *stack* fails fast on open, while a single bad page
    // later in the book falls through to `render()`'s try/catch
    // placeholder (and doesn't reject that page's `load()`, which would
    // make it unnavigable), and page turns don't pay a second decode of
    // every page.
    if (!probeState.probed) {
        const probeCanvas = document.createElement('canvas')
        probeCanvas.height = viewport.height
        probeCanvas.width = viewport.width
        await page.render({ canvasContext: probeCanvas.getContext('2d'), viewport }).promise
        probeState.probed = true
    }

    const src = URL.createObjectURL(new Blob([`
        <!DOCTYPE html>
        <html lang="en">
        <meta charset="utf-8">
        <meta name="viewport" content="width=${viewport.width}, height=${viewport.height}">
        <style>
        html, body {
            margin: 0;
            padding: 0;
        }
        /*
        https://github.com/mozilla/pdf.js/commit/bd05b255fabfc313b194bfe9a17ccded4d90fb5a
        */
        :root {
          --user-unit: 1;
          --total-scale-factor: calc(var(--scale-factor) * var(--user-unit));
          --scale-round-x: 1px;
          --scale-round-y: 1px;
        }
        ${textLayerBuilderCSS}
        ${annotationLayerBuilderCSS}
        </style>
        <div id="canvas"></div>
        <div class="textLayer"></div>
        <div class="annotationLayer"></div>
    `], { type: 'text/html' }))
    const onZoom = ({ doc, scale }) => render(page, doc, scale)
    return { src, onZoom }
}

const makeTOCItem = item => ({
    label: item.title,
    href: JSON.stringify(item.dest),
    subitems: item.items.length ? item.items.map(makeTOCItem) : null,
})

export const makePDF = async file => {
    const transport = new pdfjsLib.PDFDataRangeTransport(file.size, [])
    transport.requestDataRange = (begin, end) => {
        file.slice(begin, end).arrayBuffer().then(chunk => {
            transport.onDataRange(begin, chunk)
        })
    }
    const pdf = await pdfjsLib.getDocument({
        range: transport,
        cMapUrl: pdfjsPath('cmaps/'),
        standardFontDataUrl: pdfjsPath('standard_fonts/'),
        // Codec/color-space wasm modules (openjpeg for JPXDecode, jbig2 for
        // JBIG2Decode, qcms for ICC color conversion) — without these, pages
        // whose images use those codecs (common in scanned/picture-book
        // PDFs) throw during page.render() and the canvas stays blank; see
        // render()'s try/catch and renderPage()'s eager probe above, and
        // vendor/pdfjs/VERSION for what's vendored under wasm/.
        wasmUrl: pdfjsPath('wasm/'),
        iccUrl: pdfjsPath('wasm/'),
        isEvalSupported: false,
    }).promise

    const book = { rendition: { layout: 'pre-paginated' } }

    const { metadata, info } = await pdf.getMetadata() ?? {}
    // TODO: for better results, parse `metadata.getRaw()`
    book.metadata = {
        title: metadata?.get('dc:title') ?? info?.Title,
        author: metadata?.get('dc:creator') ?? info?.Author,
        contributor: metadata?.get('dc:contributor'),
        description: metadata?.get('dc:description') ?? info?.Subject,
        language: metadata?.get('dc:language'),
        publisher: metadata?.get('dc:publisher'),
        subject: metadata?.get('dc:subject'),
        identifier: metadata?.get('dc:identifier'),
        source: metadata?.get('dc:source'),
        rights: metadata?.get('dc:rights'),
    }

    const outline = await pdf.getOutline()
    book.toc = outline?.map(makeTOCItem)

    const cache = new Map()
    // Per-book probe latch (see renderPage()'s eager-probe comment above):
    // created fresh here, once per makePDF() call, rather than living on
    // renderPage itself.
    const probeState = { probed: false }
    book.sections = Array.from({ length: pdf.numPages }).map((_, i) => ({
        id: i,
        load: async () => {
            const cached = cache.get(i)
            if (cached) return cached
            const url = await renderPage(await pdf.getPage(i + 1), probeState)
            cache.set(i, url)
            return url
        },
        size: 1000,
    }))
    book.isExternal = uri => /^\w+:/i.test(uri)
    book.resolveHref = async href => {
        const parsed = JSON.parse(href)
        const dest = typeof parsed === 'string'
            ? await pdf.getDestination(parsed) : parsed
        const index = await pdf.getPageIndex(dest[0])
        return { index }
    }
    book.splitTOCHref = async href => {
        const parsed = JSON.parse(href)
        const dest = typeof parsed === 'string'
            ? await pdf.getDestination(parsed) : parsed
        const index = await pdf.getPageIndex(dest[0])
        return [index, null]
    }
    book.getTOCFragment = doc => doc.documentElement
    book.getCover = async () => renderPage(await pdf.getPage(1), probeState, true)
    book.destroy = () => pdf.destroy()
    return book
}
