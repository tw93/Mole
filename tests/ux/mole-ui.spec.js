const { test, expect } = require('@playwright/test');
const path = require('node:path');

const previewURL = `file://${path.resolve(__dirname, '../../macos/MoleUI/UXPreview/index.html')}`;

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

test.describe('MoleUI UX preview', () => {
  test('renders the full care workflow without layout overlap', async ({ page }) => {
    await page.goto(previewURL);

    await expect(page.getByRole('heading', { name: 'Mole System Care' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Start Care Scan' })).toBeVisible();
    await expect(page.getByText('Potential Cleanup')).toBeVisible();
    await expect(page.getByText('Recommended Cleanup')).toBeVisible();
    await expect(page.getByText('Administrator action needs approval')).toBeVisible();
    await expect(page.getByText('Partial cleanup is recoverable')).toBeVisible();
    await expect(page.getByText('Quick launchers')).toBeVisible();

    const surfaces = await visibleBoxes(page, '[data-ux-surface]');
    for (let i = 0; i < surfaces.length; i += 1) {
      for (let j = i + 1; j < surfaces.length; j += 1) {
        expect(
          overlaps(surfaces[i], surfaces[j]),
          `${surfaces[i].text} overlaps ${surfaces[j].text}`
        ).toBe(false);
      }
    }
  });

  test('keeps button and row text inside its containers', async ({ page }) => {
    await page.goto(previewURL);

    const overflowing = await page.locator('button, .row strong, .row span, .panel, .notice').evaluateAll((nodes) =>
      nodes
        .filter((node) => node.scrollWidth > node.clientWidth + 1)
        .map((node) => node.textContent.trim())
    );

    expect(overflowing).toEqual([]);
  });
});
