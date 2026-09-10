const { defineConfig } = require("@playwright/test")

const PORT = Number(process.env.E2E_PORT || 3100)

// Drives a real Chromium against the Rails app booted by e2e/boot.sh
// (isolated e2e database + library root — see that script). Run with
// `npm test` from server/e2e.
module.exports = defineConfig({
  testDir: __dirname,
  testMatch: "reader.spec.js",
  timeout: 60_000,
  workers: 1, // one isolated SQLite e2e database — no parallelism
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    viewport: { width: 800, height: 1200 },
    trace: "retain-on-failure"
  },
  webServer: {
    command: "bash e2e/boot.sh",
    cwd: `${__dirname}/..`,
    url: `http://127.0.0.1:${PORT}/up`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000
  }
})
