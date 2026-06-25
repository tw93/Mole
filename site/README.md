# Roomy Landing Page

This directory contains a static product landing page for the current Roomy CLI release.

## Files

- `index.html` is the public landing page.
- `pricing.html` is the dedicated pricing page.
- `styles.css` contains the shared minimal site styling.
- `demo-scene.html` is the deterministic browser scene used to render the demo.
- `assets/roomy-demo.mp4` is the generated demo video embedded in the page.
- `assets/roomy-demo-poster.png` is the generated poster image.
- `scripts/render-demo-video.mjs` regenerates the video and poster with Playwright plus `ffmpeg`.
- `scripts/check-site.mjs` runs responsive smoke checks and saves screenshots to `test-results/site/`.

The footer links to privacy, support, and license documents in the repository
so buyer-facing expectations stay aligned with the GPL CLI release.

Pricing copy must stay support-based. The free CLI remains the full local
cleanup engine; paid plans fund maintenance, triage, and team rollout support.

## Local Use

```bash
npm run site:render-demo
npm run site:check
```

Open `site/index.html` directly in a browser, or serve the directory with any static host.
