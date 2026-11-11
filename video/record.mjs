// Records the Lastlight demo video (silent, captioned). Usage:
//   python -m http.server 8777 -d work/reactive/lastlight/web   (in another shell)
//   node work/reactive/lastlight/video/record.mjs
// Output: work/reactive/lastlight/video/raw/*.webm -> convert with ffmpeg.
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.resolve(here, "../../../../tools/browser/package.json"));
const { chromium } = require("playwright");

const VAULT = "0x4a988f214Dc696b1933C3404Bb0B5Ff2eb703e79";
const REACTIVE = "0x50491aeb35b82531f3B93dE363c0568FEdC212c2";
const TX = {
  create: "0x025e78f212e418e9d7356bbbda0f3bbd5bf62f019af2e24e2e1317c604bb55a3",
  warn: "0x36cf239be5aef030eb1cd7de0c24123b2aa75d9fd28848830a6da552e4958de6",
  release: "0xfb0d084e1ae3ddbec997364f33cba0b17c3359a77debbcecf90d71297b052461",
};
const W = 1280, H = 720;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const card = (title, lines) => `data:text/html,${encodeURIComponent(`<!doctype html><meta charset=utf-8>
<body style="margin:0;height:100vh;display:flex;flex-direction:column;justify-content:center;padding:0 90px;
background:#0d1117;color:#e6edf3;font:26px/1.5 Segoe UI,sans-serif"><h1 style="font-size:52px;margin:0 0 24px;color:#f0b429">${title}</h1>
${lines.map((l) => `<div style="margin:6px 0">${l}</div>`).join("")}</body>`)}`;

async function caption(page, text) {
  await page.evaluate((t) => {
    let d = document.getElementById("__cap");
    if (!d) {
      d = document.createElement("div");
      d.id = "__cap";
      d.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:2147483647;background:rgba(0,0,0,.82);" +
        "color:#fff;font:22px/1.4 Segoe UI,sans-serif;padding:14px 28px;text-align:center";
      document.documentElement.appendChild(d);
    }
    d.textContent = t;
  }, text).catch(() => {});
}

async function scene(page, url, caps, { wait = 4000, scroll = 0 } = {}) {
  try { await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30000 }); } catch (e) { console.log("goto failed", url, e.message); return false; }
  await sleep(wait);
  for (const [i, [t, ms]] of caps.entries()) {
    await caption(page, t);
    if (scroll && i > 0) await page.mouse.wheel(0, scroll);
    await sleep(ms);
  }
  return true;
}

const browser = await chromium.launch({ channel: "msedge", headless: true });
const ctx = await browser.newContext({ viewport: { width: W, height: H }, recordVideo: { dir: path.join(here, "raw"), size: { width: W, height: H } } });
// Keep explorer ads out of the video: only first-party hosts load.
const ALLOW = /^(data:|https?:\/\/(127\.0\.0\.1|[^/]*blockscout\.com|[^/]*reactscan\.net|[^/]*reactive\.network|cdn\.jsdelivr\.net|[^/]*publicnode\.com)([:/]|$))/;
await ctx.route("**/*", (r) => (ALLOW.test(r.request().url()) ? r.continue() : r.abort()));
const page = await ctx.newPage();

await page.goto(card("Lastlight", [
  "A dead-man's-switch inheritance vault on Ethereum.",
  "If the owner stops checking in, the heirs get paid. Automatically.",
  "No keeper bot, no off-chain server: Reactive Network's cron drives it.",
  "<span style='color:#8b949e'>Reactive Omni Buildathon · Tessel Works</span>",
]));
await sleep(8000);

await page.goto(card("How it works", [
  "1. Owner creates a vault on Sepolia: ETH, heirs + shares, heartbeat, warning window.",
  "2. Any owner action (check-in, deposit, edit) is proof of life.",
  "3. LastlightReactive on Lasna subscribes to each vault's events and to Cron100.",
  "4. Cron tick past warnAt → <b>warn</b> callback. Past the deadline → <b>release</b> callback.",
  "5. The vault checks its own clock, pays the heirs, and pays for its callbacks itself.",
]));
await sleep(14000);

await scene(page, `http://127.0.0.1:8777/index.html?vault=${VAULT}`, [
  ["Status page for the live demo vault (30-min heartbeat, warning 15 min before the deadline, 0.02 ETH, one heir).", 7000],
  ["It reads the vault straight from Sepolia: state, plan, heirs and every event.", 6000],
  ["Event log: created + check-in → Warned (by Reactive) → HeirPaid + Released (by Reactive). Nobody touched it after creation.", 8000],
], { wait: 7000, scroll: 300 });

await scene(page, `https://eth-sepolia.blockscout.com/tx/${TX.warn}`, [
  ["Warn callback: delivered via the Reactive callback proxy 49 s after warnAt.", 7000],
], { wait: 9000 });
await scene(page, `https://eth-sepolia.blockscout.com/tx/${TX.release}?tab=logs`, [
  ["Release callback 112 s after the deadline: HeirPaid + Released. The heir got the ETH.", 8000],
], { wait: 9000 });
await scene(page, `https://lasna.reactscan.net/address/${REACTIVE}`, [
  ["LastlightReactive on Reactive Lasna: cron-driven, per-vault dynamic subscriptions, retries, round-robin across many vaults.", 8000],
], { wait: 6000 });

await page.goto(card("Try it", [
  "Code, 14 Foundry tests, deploy scripts, addresses and tx hashes:",
  "<b>github.com/tesselworksHQ/lastlight</b>",
  "Reactive: <code>" + REACTIVE + "</code>",
  "Demo vault: <code>" + VAULT + "</code>",
]));
await sleep(8000);

await ctx.close();
await browser.close();
console.log("done");
