#!/usr/bin/env node
import { chromium } from "@playwright/test";
import { existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const siteRoot = resolve(__dirname, "..");
const indexPath = resolve(siteRoot, "index.html");
const pricingPath = resolve(siteRoot, "pricing.html");
const stylesPath = resolve(siteRoot, "styles.css");
const videoPath = resolve(siteRoot, "assets/roomy-demo.mp4");
const posterPath = resolve(siteRoot, "assets/roomy-demo-poster.png");
const outputDir = resolve(siteRoot, "../test-results/site");

for (const file of [indexPath, pricingPath, stylesPath, videoPath, posterPath]) {
  if (!existsSync(file)) {
    throw new Error(`Missing required site asset: ${file}`);
  }
}

if (statSync(videoPath).size < 100_000) {
  throw new Error("Demo video exists but is unexpectedly small");
}

mkdirSync(outputDir, { recursive: true });

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function launchBrowser() {
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      return await chromium.launch();
    } catch (error) {
      lastError = error;
      if (attempt < 3) {
        await wait(500 * attempt);
      }
    }
  }
  throw lastError;
}

const browser = await launchBrowser();
const viewports = [
  { name: "desktop", width: 1440, height: 980 },
  { name: "mobile", width: 390, height: 844 }
];

const pages = [
  {
    name: "index",
    path: indexPath,
    expectedTitle: "Roomy",
    requiredSections: ["how", "demo", "features", "pricing", "faq"],
    validate(checks, viewport) {
      if (checks.heroHeight < viewport.height * 0.72 && viewport.name === "desktop") {
        throw new Error(`${viewport.name} index hero is not substantial enough`);
      }
      if (!checks.mediaReady) {
        throw new Error(`${viewport.name} index is missing demo media`);
      }
      if (!checks.bodyText.includes("Clean your Mac. See every change.")) {
        throw new Error(`${viewport.name} index hero copy is missing`);
      }
      if (!checks.bodyText.includes("Roomy Supporter") || !checks.bodyText.includes("$19/year")) {
        throw new Error(`${viewport.name} index pricing teaser is missing`);
      }
      if (!checks.commandText.includes("brew install jake-seo-cl/tap/roomy")) {
        throw new Error(`${viewport.name} install commands should use the release tap`);
      }
    }
  },
  {
    name: "pricing",
    path: pricingPath,
    expectedTitle: "Simple pricing for a focused Mac cleaner.",
    requiredSections: ["plans"],
    validate(checks) {
      if (!checks.bodyText.includes("$19") || !checks.bodyText.includes("$99")) {
        throw new Error("pricing page should include supporter and team prices");
      }
      if (!checks.bodyText.includes("CleanMyMac") || !checks.bodyText.includes("$3.33/month")) {
        throw new Error("pricing page should explain the CleanMyMac undercut");
      }
      if (!checks.bodyText.includes("$1.58/month")) {
        throw new Error("pricing page should show the Roomy monthly equivalent");
      }
      if (!checks.bodyText.includes("same GPL CLI") || checks.bodyText.includes("Pro unlocks")) {
        throw new Error("pricing page should keep paid plans GPL-compatible");
      }
    }
  }
];

for (const viewport of viewports) {
  for (const sitePage of pages) {
    const page = await browser.newPage({ viewport });
    await page.goto(pathToFileURL(sitePage.path).href, { waitUntil: "networkidle" });

    const checks = await page.evaluate((requiredSections) => {
      const hero = document.querySelector(".hero, .pricing-hero");
      const video = document.querySelector("#demo video");
      const bodyWidth = document.documentElement.clientWidth;
      const overflow = document.documentElement.scrollWidth - bodyWidth;
      const h1Text = document.querySelector("h1")?.textContent?.trim();
      const sectionsPresent = requiredSections.every((id) => Boolean(document.getElementById(id)));
      const mediaReady = Boolean(video?.querySelector("source")?.getAttribute("src"));
      const heroRect = hero?.getBoundingClientRect();
      const commandText = document.querySelector(".command-row")?.textContent || "";
      const footerText = document.querySelector(".site-footer")?.textContent || "";
      const bodyText = document.body.textContent || "";

      return {
        overflow,
        h1Text,
        sectionsPresent,
        mediaReady,
        heroHeight: heroRect?.height || 0,
        commandText,
        footerText,
        bodyText
      };
    }, sitePage.requiredSections);

    if (checks.overflow > 2) {
      throw new Error(`${viewport.name} ${sitePage.name} has horizontal overflow of ${checks.overflow}px`);
    }
    if (checks.h1Text !== sitePage.expectedTitle) {
      throw new Error(`${viewport.name} ${sitePage.name} H1 should be "${sitePage.expectedTitle}"`);
    }
    if (!checks.sectionsPresent) {
      throw new Error(`${viewport.name} ${sitePage.name} is missing required sections`);
    }
    if (!checks.footerText.includes("Privacy") || !checks.footerText.includes("Support") || !checks.footerText.includes("License")) {
      throw new Error(`${viewport.name} ${sitePage.name} footer should link privacy, support, and license guidance`);
    }

    sitePage.validate(checks, viewport);

    await page.screenshot({ path: resolve(outputDir, `${viewport.name}-${sitePage.name}.png`), fullPage: true });
    await page.close();
  }
}

await browser.close();
console.log(`Site checks passed. Screenshots written to ${outputDir}`);
