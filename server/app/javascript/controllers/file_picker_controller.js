import { Controller } from "@hotwired/stimulus"

// Lists chosen files inside the dropzone and supports drag & drop.
export default class extends Controller {
  static targets = ["input", "list", "prompt"]

  connect() {
    this.element.addEventListener("dragover", (e) => {
      e.preventDefault()
      this.element.classList.add("is-dragover")
    })
    this.element.addEventListener("dragleave", () => {
      this.element.classList.remove("is-dragover")
    })
    this.element.addEventListener("drop", (e) => {
      e.preventDefault()
      this.element.classList.remove("is-dragover")
      this.inputTarget.files = e.dataTransfer.files
      this.update()
    })
  }

  update() {
    const files = Array.from(this.inputTarget.files)
    const items = files.map((file) => {
      const item = document.createElement("li")
      item.textContent = file.name
      return item
    })
    this.listTarget.replaceChildren(...items)
    if (files.length > 0) {
      this.promptTarget.textContent = `${files.length} file${files.length > 1 ? "s" : ""} ready`
    }
  }
}
