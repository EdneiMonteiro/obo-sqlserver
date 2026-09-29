const { defineConfig } = require("@playwright/test");

// Do not persist identity-provider DOM snapshots when interactive authentication fails.
process.env.PLAYWRIGHT_NO_COPY_PROMPT = "1";

module.exports = defineConfig({
  testDir: ".",
  projects: [
    { name: "ui", testMatch: "ui.spec.js", use: { headless: true, baseURL: "https://ui.example.test" } },
    { name: "live", testMatch: "documents.spec.js", use: { headless: false, baseURL: process.env.OBO_BASE_URL } }
  ],
  timeout: 240000,
  workers: 1,
  retries: 0,
  reporter: "list",
  use: {
    ignoreHTTPSErrors: false,
    trace: "off",
    screenshot: "off",
    video: "off"
  }
});
