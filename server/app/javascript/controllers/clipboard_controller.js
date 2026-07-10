import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { text: String }

  async copy(event) {
    await navigator.clipboard.writeText(this.textValue)
    const button = event.currentTarget
    const label = button.textContent
    button.textContent = "copied"
    setTimeout(() => (button.textContent = label), 1500)
  }
}
