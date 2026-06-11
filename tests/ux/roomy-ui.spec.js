const { test, expect } = require('@playwright/test');
const path = require('node:path');

const previewURL = `file://${path.resolve(__dirname, '../../macos/RoomyUI/UXPreview/index.html')}`;

async function visibleBoxes(page, selector) {
  return await page.locator(selector).evaluateAll((nodes) =>
    nodes
      .map((node) => {
        const rect = node.getBoundingClientRect();
        return {
          x: rect.x,
          y: rect.y,
          width: rect.width,
          height: rect.height,
          text: node.textContent.trim()
        };
      })
      .filter((box) => box.width > 0 && box.height > 0)
  );
}

function overlaps(a, b) {
  const pad = 1;
  return !(
    a.x + a.width <= b.x + pad ||
    b.x + b.width <= a.x + pad ||
    a.y + a.height <= b.y + pad ||
    b.y + b.height <= a.y + pad
  );
}

async function expectNoSurfaceOverlap(page) {
  const surfaces = await visibleBoxes(page, '[data-ux-surface]');
  for (let i = 0; i < surfaces.length; i += 1) {
    for (let j = i + 1; j < surfaces.length; j += 1) {
      expect(
        overlaps(surfaces[i], surfaces[j]),
        `${surfaces[i].text} overlaps ${surfaces[j].text}`
      ).toBe(false);
    }
  }
}

test.describe('RoomyUI UX preview', () => {
  test('renders the full care workflow without layout overlap', async ({ page }) => {
    await page.goto(previewURL);

    await expect(page.getByRole('heading', { name: 'Free Up Your Mac' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Preview Cleanup' })).toHaveCount(2);
    await expect(page.getByRole('button', { name: 'Move 966 Reviewed Items to Trash' })).toHaveCount(1);
    await expect(page.getByText('Clean My Mac')).toHaveCount(0);
    await expect(page.getByText('Free Space')).toBeVisible();
    await expect(page.getByText('Disk Used')).toBeVisible();
    await expect(page.getByText('Potential Cleanup')).toBeVisible();
    await expect(page.getByLabel('Care summary').getByText('Scan Access')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open Full Disk Access' })).toBeVisible();
    await expect(page.getByLabel('First-run and recovery visibility').getByText('Ready for your first scan')).toBeVisible();
    await expect(page.getByLabel('First-run safeguards').getByText('No files changed', { exact: true })).toBeVisible();
    await expect(page.getByLabel('First-run safeguards').getByText('Estimates load after scan', { exact: true })).toBeVisible();
    await expect(page.getByText('0 GB')).toHaveCount(0);
    await expect(page.getByText('0 items')).toHaveCount(0);
    await expect(page.getByLabel('First-run and recovery visibility').getByText('Recovery & Reports')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open Cleanup Report' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Show in Trash' })).toBeVisible();
    await expect(page.getByLabel('Recovery safeguards').getByText('Operation journal saved', { exact: true })).toBeVisible();
    await expect(page.getByLabel('Recovery safeguards').getByText('Report includes skipped paths', { exact: true })).toBeVisible();
    await expect(page.getByLabel('Cleanup safeguards').getByText('Preview cleanup', { exact: true })).toBeVisible();
    await expect(page.getByLabel('Cleanup safeguards').getByText('Review plan', { exact: true })).toBeVisible();
    await expect(page.getByLabel('Cleanup safeguards').getByText('Trash-backed', { exact: true })).toBeVisible();
    await expect(page.getByLabel('Cleanup safeguards').getByText('Protected paths skipped', { exact: true })).toBeVisible();
    await expect(page.getByText('966 items', { exact: true })).toHaveCount(2);
    await expect(page.getByText('Recommended Cleanup')).toBeVisible();
    await expect(page.getByText('Showing 4 of 51 groups · 47 groups hidden until you open the full plan')).toBeVisible();
    await expect(page.getByLabel('Trash confirmation copy').getByText('Roomy revalidates selected paths')).toBeVisible();
    await expect(page.getByText('Secondary Cleanup Tools')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Recent Activity' })).toBeVisible();
    await expect(page.getByText('Showing 2 of 8 journal entries · 6 entries hidden in this preview')).toBeVisible();
    await expect(page.getByText('Showing 5 of 9 signals · 4 signals hidden in this preview')).toBeVisible();
    await expect(page.getByText('Quick launchers')).toBeVisible();
    await expect(page.getByText('CPU and memory')).toHaveCount(0);
    await expect(page.getByText('Full Disk Access is a one-time option')).toHaveCount(0);
    await expect(page.getByText('Administrator action needs approval')).toHaveCount(0);

    await expectNoSurfaceOverlap(page);
  });

  test('keeps button and row text inside its containers', async ({ page }) => {
    const viewports = [
      { width: 1280, height: 900 },
      { width: 390, height: 900 }
    ];

    for (const viewport of viewports) {
      await page.setViewportSize(viewport);
      await page.goto(previewURL);

      const pageWidths = await page.evaluate(() => ({
        bodyClientWidth: document.body.clientWidth,
        bodyScrollWidth: document.body.scrollWidth,
        clientWidth: document.documentElement.clientWidth,
        scrollWidth: document.documentElement.scrollWidth
      }));

      expect(pageWidths.scrollWidth, `document overflow at ${viewport.width}px`).toBeLessThanOrEqual(pageWidths.clientWidth + 1);
      expect(pageWidths.bodyScrollWidth, `body overflow at ${viewport.width}px`).toBeLessThanOrEqual(pageWidths.bodyClientWidth + 1);

      const overflowing = await page.locator('button, .row strong, .row span, .panel, .notice, .count-note, .callout strong, .callout span, .state-card h2, .state-card p').evaluateAll((nodes) =>
        nodes
          .filter((node) => node.scrollWidth > node.clientWidth + 1)
          .map((node) => node.textContent.trim())
      );

      expect(overflowing, `text overflow at ${viewport.width}px`).toEqual([]);
      await expectNoSurfaceOverlap(page);
    }
  });

  test('uses restrained flat surfaces instead of decorative gradients', async ({ page }) => {
    await page.goto(previewURL);

    const styleText = await page.locator('style').textContent();
    expect(styleText).not.toMatch(/linear-gradient|radial-gradient|backdrop-filter/);
  });
});
