const { test, expect } = require("@playwright/test")
const fs = require("node:fs")
const path = require("node:path")

// IDs are written by e2e/seed.rb on every boot — read them lazily inside
// beforeAll (Playwright collects test files before the webServer has seeded).
let seed
test.beforeAll(() => {
  seed = JSON.parse(fs.readFileSync(path.join(__dirname, ".seed.json"), "utf8"))
})

async function signIn(page) {
  await page.goto("/session/new")
  await page.getByLabel("Email").fill("e2e@example.com")
  await page.getByLabel("Password").fill("e2e-password")
  await page.getByRole("button", { name: "Sign in" }).click()
  await expect(page).not.toHaveURL(/session\/new/)
}

async function openBook(page, id) {
  await page.goto(`/books/${id}/read`)
  // hideLoading() flips the `hidden` attribute once the book renders —
  // the one reliable "reader is interactive" signal.
  await expect(page.locator(".reader-loading")).toBeHidden({ timeout: 30_000 })
}

// The chrome bars auto-hide after a few seconds (AUTO_HIDE_MS); a tap in the
// middle tap zone toggles them back (onZoneTap). Needed before any click on
// top-bar buttons, which are translated off-viewport while hidden.
async function revealChrome(page) {
  const root = page.locator("#reader-root")
  const visible = await root.evaluate((el) => el.classList.contains("reader-chrome-visible"))
  if (!visible) {
    await page.mouse.click(400, 600)
    await expect(root).toHaveClass(/reader-chrome-visible/)
  }
}

test("fixed-layout book opens in the reader without JS errors", async ({ page }) => {
  const errors = []
  page.on("pageerror", (error) => errors.push(error))

  await signIn(page)
  await openBook(page, seed.fxlId)

  await expect(page.locator("foliate-view")).toBeVisible()
  await expect(page.locator(".reader-readout")).toHaveText(/\d+%/)
  expect(errors).toEqual([])
})

test("zoom mode shows the overlay, zoom steps apply, overlay turns pages; fit mode restores", async ({ page }) => {
  await signIn(page)
  await openBook(page, seed.fxlId)

  const root = page.locator("#reader-root")
  const controls = page.locator(".reader-fxl-controls")
  const readout = page.locator(".reader-readout")

  // Enter zoom mode from the settings sheet.
  await revealChrome(page)
  await page.getByRole("button", { name: "Display settings" }).click()
  await page.getByRole("button", { name: "Zoom", exact: true }).click()
  await expect(root).toHaveAttribute("data-page-mode", "zoom")
  await page.keyboard.press("Escape") // close the sheet — it sits above the overlay

  // The semi-transparent overlay is visible and stays so.
  await expect(controls).toBeVisible()

  // Zoom steps accumulate on top of the fit scale.
  await expect(root).toHaveAttribute("data-zoom-factor", "1")
  await page.locator(".reader-fxl-zoom .reader-fxl-btn").first().click() // zoom in
  await expect(root).toHaveAttribute("data-zoom-factor", "1.4")

  // The overlay's next-page button relocates the reader.
  await expect(readout).toHaveText(/\d+%/)
  const before = await readout.textContent()
  await page.locator(".reader-fxl-btn--next").click()
  await expect(readout).not.toHaveText(before)

  // Fit mode again: overlay hidden, zoom factor reset.
  await revealChrome(page)
  await page.getByRole("button", { name: "Display settings" }).click()
  await page.getByRole("button", { name: "Fit screen" }).click()
  await expect(root).toHaveAttribute("data-page-mode", "fit")
  await expect(root).toHaveAttribute("data-zoom-factor", "1")
  await page.keyboard.press("Escape")
  await expect(controls).toBeHidden()
})

test("reflowable book hides the page-mode settings row", async ({ page }) => {
  await signIn(page)
  await openBook(page, seed.reflowableId)

  await revealChrome(page)
  await page.getByRole("button", { name: "Display settings" }).click()
  await expect(page.locator('[data-reader-target="pageModeRow"]')).toBeHidden()
})
