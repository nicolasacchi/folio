import { Controller } from "@hotwired/stimulus"

// Periodically reloads the enclosing turbo-frame. Rendered only while
// background work is in flight, so polling stops by itself.
export default class extends Controller {
  static values = { interval: { type: Number, default: 4000 } }

  connect() {
    this.frame = this.element.closest("turbo-frame")
    if (!this.frame) return
    this.frame.src ||= window.location.href
    this.timer = setInterval(() => this.frame.reload(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }
}
