/* The launch screens, to match the icon (2026.11.22): the piñata on peach, so opening the app
 * carries straight on from the icon you tapped.
 *
 *   node tools/build-launch.mjs        (needs playwright; no server)
 *
 * Writes the iPhone app's launch image (ios/.../Splash.imageset, one 2732px square that
 * iOS fills the screen with, centre-cropped) and the home-screen web app's per-phone launch
 * images (splash/splash-<w>x<h>.png), and re-stamps their links in index.html so a phone that
 * cached the old ones fetches these. Replaces what build-splash.mjs made (the wordmark on black).
 */
import { chromium } from 'playwright';
import { readFileSync, writeFileSync } from 'fs';
import { createHash } from 'crypto';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const EXEC = process.env.CHROME || '/opt/pw-browsers/chromium';
const ART = readFileSync(join(ROOT, 'tools/art/pinata-full.png')).toString('base64');
const ASPECT = 578 / 701;
const PEACH_LIT = '#fbe9d3', PEACH = '#f3cfa6';
// Same sizes as build-splash.mjs: every iPhone screen iOS might match exactly.
const SCREENS = [[440,956,3],[430,932,3],[428,926,3],[420,912,3],[414,896,3],[414,896,2],[414,736,3],[402,874,3],[393,852,3],[390,844,3],[375,812,3],[375,667,2]];
/* He is 46% of the screen's width, a touch above the middle (the optical centre). On the
   square image iOS crops to the screen, that width is taken from a phone-shaped centre slice. */
const FRAC = 0.46;
const page = (W, H, pinW)=> `<style>html,body{margin:0;height:100%}
  body{background:radial-gradient(120% 70% at 30% 20%, ${PEACH_LIT}, ${PEACH});display:flex;align-items:center;justify-content:center}
  img{width:${pinW}px;height:${Math.round(pinW / ASPECT)}px;display:block;margin-bottom:${Math.round(H * 0.04)}px}</style>
  <img src="data:image/png;base64,${ART}" alt="">`;

const browser = await chromium.launch({ executablePath: EXEC });
const p = await browser.newPage({ deviceScaleFactor: 1 });
const out = [];
for (const [w, h, dpr] of SCREENS) {
  const W = w * dpr, H = h * dpr;
  await p.setViewportSize({ width: W, height: H });
  await p.setContent(page(W, H, Math.round(W * FRAC)));
  await p.waitForTimeout(120);
  out.push({ name: `splash-${W}x${H}.png`, png: await p.screenshot() });
}
// The app's launch image: 2732 square, iOS aspect-fills and centre-crops it, so he is sized
// against a 9:19.5 slice of it.
await p.setViewportSize({ width: 2732, height: 2732 });
await p.setContent(page(2732, 2732, Math.round(2732 * 9 / 19.5 * FRAC)));
await p.waitForTimeout(200);
const square = await p.screenshot();
await browser.close();

for (const o of out) writeFileSync(join(ROOT, 'splash', o.name), o.png);
const SET = join(ROOT, 'ios/App/App/Assets.xcassets/Splash.imageset');
for (const f of ['splash-2732x2732.png', 'splash-2732x2732-1.png', 'splash-2732x2732-2.png']) writeFileSync(join(SET, f), square);

const STAMP = createHash('sha1').update(square).digest('hex').slice(0, 8);
const file = join(ROOT, 'index.html');
let html = readFileSync(file, 'utf8');
const n = (html.match(/splash\/splash-\d+x\d+\.png\?v=[a-f0-9]+/g) || []).length;
if (!n) throw new Error('no launch image links found to stamp');
html = html.replace(/(splash\/splash-\d+x\d+\.png)\?v=[a-f0-9]+/g, `$1?v=${STAMP}`);
writeFileSync(file, html);
console.log(`v=${STAMP} · ${out.length} web launch images · app launch image 2732² · ${n} links re-stamped`);
