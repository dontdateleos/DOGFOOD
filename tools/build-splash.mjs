/* Regenerates the launch screens an iPhone shows while the home-screen app opens, FROM THE APP.
 *
 * Same rule as build-icon.mjs, for the same reason: the splash is the masthead's own lockup —
 * the stacked DOG FOOD and the mark beside it — lifted off the running page, so a recoloured
 * wordmark, a re-kerned letter or a redrawn mark shows up here the next time this runs instead
 * of leaving a launch screen that no longer matches the app it opens into.
 *
 *   npm i playwright                   (not vendored; same as groundcheck)
 *   python3 -m http.server 8899        (from the repo root)
 *   node tools/build-splash.mjs
 *
 * Writes splash/splash-<w>x<h>.png, one per iPhone screen below, and rewrites the
 * apple-touch-startup-image links in index.html to match. Every URL carries ?v=<stamp>, a hash
 * of the art, for the reason build-icon gives: iOS keeps what it installed, so a changed
 * picture has to be a changed address.
 *
 * iOS reads these ONLY when the app is added to the home screen, and only the one whose media
 * query matches the phone exactly — no match, no splash, just the blank ground. That is why the
 * list is long. Android needs none of this: it builds its own launch screen from the
 * manifest's background_color and icon.
 */
import { chromium } from 'playwright';
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { createHash } from 'crypto';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const URL_ = process.env.ICON_URL || 'http://localhost:8899/index.html';
const EXEC = process.env.CHROME || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';

/* The ground is the manifest's background_color, read from the manifest rather than repeated:
   it is the colour the standalone app paints before the page does, and the colour Android's
   own splash uses, so both platforms open on the same black. */
const GROUND = JSON.parse(readFileSync(join(ROOT, 'manifest.webmanifest'), 'utf8')).background_color;

/* Portrait iPhones, as iOS reports them to a media query: CSS width x height at a pixel ratio.
   Several models share a row — that is the point of keying on the screen, not the phone. */
const SCREENS = [
  [440, 956, 3],   // 16 Pro Max, 17 Pro Max
  [430, 932, 3],   // 14 Pro Max, 15 Plus/Pro Max, 16 Plus
  [428, 926, 3],   // 12/13 Pro Max, 14 Plus
  [420, 912, 3],   // Air
  [414, 896, 3],   // XS Max, 11 Pro Max
  [414, 896, 2],   // XR, 11
  [414, 736, 3],   // 6s/7/8 Plus
  [402, 874, 3],   // 16 Pro, 17, 17 Pro
  [393, 852, 3],   // 14 Pro, 15, 15 Pro, 16, 16e
  [390, 844, 3],   // 12, 12 Pro, 13, 13 Pro, 14
  [375, 812, 3],   // X, XS, 11 Pro, 12 mini, 13 mini
  [375, 667, 2],   // 6s/7/8, SE 2nd and 3rd gen
];
/* How wide the lockup sits, as a fraction of the screen's width. Wide enough to read as the
   name, not the poster: the masthead draws it at about 45%, and a launch screen that shouts
   bigger than the app it opens into is a different brand for half a second. */
const FRAC = 0.5;
// Drawn this many times over and scaled DOWN onto every screen, so no screen gets an upscale.
const LIFT = 4;

const browser = await chromium.launch({ executablePath: EXEC });
const page = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: LIFT });
await page.goto(URL_, { waitUntil: 'networkidle' });
await page.waitForTimeout(2500);
/* The launch tab's colours, which is what the splash hands over to. First run lands on it too,
   so there is no onboarding to get past. */
await page.evaluate(() => activateTab('insights'));
await page.waitForTimeout(1600);
const box = await page.evaluate((ground) => {
  // Parked exactly as build-icon parks it: face on, eyes open and centred, no squash in flight.
  if (mcState.raf) { cancelAnimationFrame(mcState.raf); mcState.raf = null; }
  mcState.step = null; mcState.queue = [];
  mcState.rx = 0; mcState.ry = 0; mcState.rz = 0;
  mcState.blink = 1; mcState.gx = 0; mcState.gy = 0;
  mcState.body = null; mcState.sx = 1; mcState.sy = 1; mcState.ty = 0;
  drawMarkCube();
  /* Everything in the masthead that is not the lockup goes: the date, the tab line, the score,
     the sleep z's, the tab strip and the arches behind. Hidden, not removed, so nothing reflows
     and the mark stays exactly where the wordmark expects it. Motion stops too, or the capture
     is whatever frame an idle loop happened to be on. */
  const s = document.createElement('style');
  s.textContent = `*,*::before,*::after{animation:none!important;transition:none!important}
    .header-brand{background:${ground}!important}
    .header-brand::before,.header-brand::after{display:none!important}
    #headerDate,#currentTabLabel,#headerScoreBtn,.eye-zzz,.header-brand > .tabs{visibility:hidden!important}`;
  document.head.appendChild(s);
  const rects = [...document.querySelectorAll('.header-brand h1 .logo-line span'),
                 document.getElementById('headerMark')].map(e => e.getBoundingClientRect());
  const x0 = Math.min(...rects.map(r => r.left)),  y0 = Math.min(...rects.map(r => r.top));
  const x1 = Math.max(...rects.map(r => r.right)), y1 = Math.max(...rects.map(r => r.bottom));
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}, GROUND);
await page.waitForTimeout(300);
/* A few points of the ground around the lockup, because a glyph's ink can run a hair past its
   box (the FOOD's D does) and a clip on the box shaves it. The ground is the same colour as the
   splash, so the margin is invisible once composed. */
const PAD = 6;
const clip = { x: box.x - PAD, y: box.y - PAD, width: box.w + PAD * 2, height: box.h + PAD * 2 };
const lockup = await page.screenshot({ clip });
await page.close();
console.log(`lockup ${box.w.toFixed(1)}x${box.h.toFixed(1)}pt on ${GROUND}`);

const out = [];
const comp = await browser.newPage({ deviceScaleFactor: 1 });
const src = `data:image/png;base64,${lockup.toString('base64')}`;
for (const [w, h, dpr] of SCREENS) {
  const W = w * dpr, H = h * dpr;
  await comp.setViewportSize({ width: W, height: H });
  /* Centred on the screen's middle, nudged up a touch: optical centre, and it clears the home
     indicator by more than it clears the island. */
  const lw = Math.round(W * FRAC * (clip.width / box.w));
  await comp.setContent(`<style>html,body{margin:0;height:100%;background:${GROUND}}
    body{display:flex;align-items:center;justify-content:center}
    img{width:${lw}px;height:auto;display:block;margin-bottom:${Math.round(H * 0.04)}px}</style>
    <img src="${src}">`);
  await comp.waitForTimeout(150);
  out.push({ w, h, dpr, name: `splash-${W}x${H}.png`, png: await comp.screenshot() });
}
await browser.close();

const STAMP = createHash('sha1').update(lockup).update(GROUND).digest('hex').slice(0, 8);
mkdirSync(join(ROOT, 'splash'), { recursive: true });
for (const o of out) writeFileSync(join(ROOT, 'splash', o.name), o.png);

const links = out.map(o =>
  `<link rel="apple-touch-startup-image" media="(device-width: ${o.w}px) and (device-height: ${o.h}px)`
  + ` and (-webkit-device-pixel-ratio: ${o.dpr}) and (orientation: portrait)" href="splash/${o.name}?v=${STAMP}">`).join('\n');
const file = join(ROOT, 'index.html');
let html = readFileSync(file, 'utf8');
/* Every existing startup link is dropped and the fresh set goes in right after the touch icon,
   so a screen taken off the list disappears and the script stays re-runnable. */
html = html.replace(/<link rel="apple-touch-startup-image"[^>]*>\n/g, '');
const icon = /(<link rel="apple-touch-icon"[^>]*>\n)/;
if (!icon.test(html)) throw new Error('apple-touch-icon link not found; the splash links go after it');
html = html.replace(icon, `$1${links}\n`);
writeFileSync(file, html);
console.log(`v=${STAMP} · ${out.length} screens · ${out.reduce((n, o) => n + o.png.length, 0)}B`);
