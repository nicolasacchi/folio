import { Controller } from "@hotwired/stimulus"

// Paired with the "poll" controller on reader/show.html.erb's
// @preparing_conversion branch: poll keeps reloading the turbo-frame every
// few seconds so the page flips over to the real reader (or the
// "no readable file" fallback) the moment the conversion finishes/fails —
// but on its own that leaves the spinner running forever if a conversion
// genuinely stalls, indistinguishable from a hang. This adds a client-side
// timeout: once startedAtValue (the conversion's created_at, seconds since
// epoch — a server timestamp, so it survives every frame reload rather
// than resetting like a JS-side counter would) is older than timeoutValue,
// swap the spinner for a fallback message with retry/back actions.
export default class extends Controller {
  static targets = [ "waiting", "timedOut" ]
  static values = {
    startedAt: Number, // seconds since epoch
    timeout: { type: Number, default: 90_000 } // ms
  }

  connect() {
    const elapsedMs = Date.now() - this.startedAtValue * 1000
    const remaining = this.timeoutValue - elapsedMs
    if (remaining <= 0) this.showTimeout()
    else this.timer = setTimeout(() => this.showTimeout(), remaining)
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  showTimeout() {
    if (this.hasWaitingTarget) this.waitingTarget.hidden = true
    if (this.hasTimedOutTarget) this.timedOutTarget.hidden = false
  }

  retry() {
    window.location.reload()
  }
}
