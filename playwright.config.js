const { defineConfig, devices } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests/ux',
  timeout: 30_000,
  reporter: [['list']],
  use: {
    trace: 'retain-on-failure'
  },
  projects: [
    {
      name: 'desktop-chromium',
      use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 960 } }
    },
    {
      name: 'compact-chromium',
      use: { ...devices['Desktop Chrome'], viewport: { width: 900, height: 760 } }
    }
  ]
});
