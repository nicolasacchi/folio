import { Controller } from "@hotwired/stimulus"

// Add/remove condition rows on the smart shelf form. Each row is just
// three plain inputs named smart_shelf[condition_field][],
// smart_shelf[condition_op][], smart_shelf[condition_value][] — Rails
// collects same-named array params in DOM order, so no per-row index
// bookkeeping is needed here or on the server; SmartShelvesController
// zips the three arrays back into {field, op, value} conditions, and
// SmartShelf's whitelist validation has the final say over what's valid.
export default class extends Controller {
  static targets = ["rows", "template"]

  add(event) {
    event.preventDefault()
    this.rowsTarget.appendChild(this.templateTarget.content.cloneNode(true))
  }

  remove(event) {
    event.preventDefault()
    event.currentTarget.closest("[data-smart-shelf-conditions-target='row']").remove()
  }
}
