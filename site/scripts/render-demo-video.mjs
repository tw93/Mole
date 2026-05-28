#!/usr/bin/env node
import { chromium } from "@playwright/test";
import { spawnSync } from "node:child_process";
import { mkdirSync, rmSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const siteRoot = resolve(__dirname, "..");
const framesDir = resolve(siteRoot, ".frames");
const assetsDir = resolve(siteRoot, "assets");
const demoHtml = resolve(siteRoot, "demo-scene.html");
const videoPath = resolve(assetsDir, "roomy-demo.mp4");
const posterPath = resolve(assetsDir, "roomy-demo-poster.png");
const totalFrames = 144;
const fps = 24;

rmSync(framesDir, { recursive: true, force: true });
mkdirSync(framesDir, { recursive: true });
mkdirSync(assetsDir, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1 });
const baseUrl = pathToFileURL(demoHtml).href;

for (let frame = 0; frame < totalFrames; frame += 1) {
  await page.goto(`${baseUrl}?frame=${frame}&total=${totalFrames}`, { waitUntil: "networkidle" });
  await page.screenshot({
    path: resolve(framesDir, `frame-${String(frame).padStart(4, "0")}.png`),
    animations: "disabled"
  });
  if (frame === 34) {
    await page.screenshot({ path: posterPath, animations: "disabled" });
  }
}

await browser.close();

const ffmpeg = spawnSync("ffmpeg", [
  "-y",
  "-framerate", String(fps),
  "-i", resolve(framesDir, "frame-%04d.png"),
  "-vf", "format=yuv420p",
  "-movflags", "+faststart",
  "-c:v", "libx264",
  "-crf", "24",
  videoPath
], { stdio: "inherit" });

rmSync(framesDir, { recursive: true, force: true });

if (ffmpeg.status !== 0) {
  process.exit(ffmpeg.status || 1);
}

console.log(`Created ${videoPath}`);
console.log(`Created ${posterPath}`);
