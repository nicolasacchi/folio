# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# foliate-js is served unfingerprinted from public/ (see
# public/reader/foliate-js-78914ae/VERSION): its internal imports are
# relative paths that break under propshaft digesting. The directory's
# short sha is the cache-bust key — bump both here and the vendored copy
# together when updating.
pin "foliate-view", to: "/reader/foliate-js-78914ae/view.js"
pin "foliate-epubcfi", to: "/reader/foliate-js-78914ae/epubcfi.js"
pin "foliate-overlayer", to: "/reader/foliate-js-78914ae/overlayer.js"
pin "foliate-footnotes", to: "/reader/foliate-js-78914ae/footnotes.js"
