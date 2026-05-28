#!/usr/bin/env node
import { chromium } from "@playwright/test";
import { existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const siteRoot = resolve(__dirname, "..");
const indexPath = resolve(siteRoot, "index.html");
const videoPath = resolve(siteRoot, "assets/roomy-demo.mp4");
const posterPath = resolve(siteRoot, "assets/roomy-demo-poster.png");
const outputDir = resolve(siteRoot, "../test-results/site");

for (const file of [indexPath, videoPath, posterPath]) {
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

for (const viewport of viewports) {
  const page = await browser.newPage({ viewport });
  await page.goto(pathToFileURL(indexPath).href, { waitUntil: "networkidle" });

  const checks = await page.evaluate(() => {
    const hero = document.querySelector(".hero");
    const video = document.querySelector("#demo video");
    const bodyWidth = document.documentElement.clientWidth;
    const overflow = document.documentElement.scrollWidth - bodyWidth;
    const h1Text = document.querySelector("h1")?.textContent?.trim();
    const sectionIds = ["demo", "positioning", "compare", "get"];
    const sectionsPresent = sectionIds.every((id) => Boolean(document.getElementById(id)));
    const mediaReady = Boolean(video?.querySelector("source")?.getAttribute("src"));
    const heroRect = hero?.getBoundingClientRect();
    const commandText = document.querySelector(".command-box")?.textContent || "";
    const footerText = document.querySelector(".site-footer")?.textContent || "";

    return {
      overflow,
      h1Text,
      sectionsPresent,
      mediaReady,
      heroHeight: heroRect?.height || 0,
      commandText,
      footerText
    };
  });

  if (checks.overflow > 2) {
    throw new Error(`${viewport.name} has horizontal overflow of ${checks.overflow}px`);
  }
  if (checks.h1Text !== "Roomy") {
    throw new Error(`${viewport.name} H1 should be the product name`);
  }
  if (!checks.sectionsPresent || !checks.mediaReady) {
    throw new Error(`${viewport.name} is missing required sections or media`);
  }
  if (checks.heroHeight < viewport.height * 0.7) {
    throw new Error(`${viewport.name} hero is not substantial enough`);
  }
  if (!checks.commandText.includes("brew install tw93/tap/roomy")) {
    throw new Error(`${viewport.name} install commands should use the release tap`);
  }
  if (!checks.footerText.includes("Privacy") || !checks.footerText.includes("Support")) {
    throw new Error(`${viewport.name} footer should link privacy and support guidance`);
  }

  await page.screenshot({ path: resolve(outputDir, `${viewport.name}.png`), fullPage: true });
  await page.close();
}

await browser.close();
console.log(`Site checks passed. Screenshots written to ${outputDir}`);
