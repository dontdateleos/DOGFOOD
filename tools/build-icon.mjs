/* Regenerates every icon the app ships, FROM THE APP.
 *
 * The icon is the mark, and the only way it cannot drift from the mark is to be the same
 * drawing: this loads the running page, parks the solid face on, and lifts the SVG that
 * drawMarkCube produced. Change the mark's colour, its resting angle or its geometry and this
 * picks all of it up; redraw the icon by hand and it is wrong the next time any of that moves.
 *
 *   npm i playwright                   (not vendored; same as groundcheck)
 *   python3 -m http.server 8899        (from the repo root)
 *   node tools/build-icon.mjs
 *
 * Writes icon-512.png and icon-512-maskable.png (the manifest installs one per purpose),
 * apple-touch-icon.png (iOS reads this one and nothing else when you Add to Home Screen), and
 * the inline 32px tab icon in index.html. Every icon URL it writes carries ?v=<stamp>, the
 * stamp being a hash of the art, so a changed icon is a changed URL and no cache anywhere can
 * answer with the old one.
 */
import { chromium } from 'playwright';
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { createHash } from 'crypto';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const URL_ = process.env.ICON_URL || 'http://localhost:8899/index.html';
const EXEC = process.env.CHROME || '/opt/pw-browsers/chromium';
/* The mark's own two colours are READ off the page rather than repeated here, for the same
   reason the drawing is: a copy of them in this file is a copy that goes stale the next time
   the mark is repainted, and it went stale exactly once already. The limb darkening needs no
   substitution either — it is black at an alpha, which is a literal already.
   The ground is this file's one real decision, and it is the OPPOSITE of the mark's body: a
   sand sphere on cream is mush and an ink one on the app's black is a hole. Picked from the
   body's luminance so it stays right whatever colour the mark is next. */
const DARK_GROUND = '#0c0d0b', LIGHT_GROUND = '#fbfaf6';
/* How big the mark is drawn, as a fraction of the tile's WIDTH — its reach, edge to edge for a
   round mark and corner to corner for one with corners. Over 1 means the mark overruns the tile
   and the tile crops it, which is the whole idea here: the crescent and the eyes are the mark,
   the sphere's outline is not, and at 29pt the outline is the only part that still reads. Let
   it run off and the eyes get 3.85px at 29pt instead of the 2.05px a fitted sphere leaves.
   Maskable crops take the central 80% — a circle of radius 0.4S — and at this size the eyes and
   the crescent are both inside it, which is the constraint that fixes the ceiling. */
/* THE PIÑATA ON PEACH (2026.11.22). The mascot became a paper piñata, a picture rather than a
   drawing, so the icon is composed here from the full-size cutout (tools/art/pinata-full.png;
   the app itself uses mascot/pinata.png, a 360px copy) on the peach of the morning masthead,
   lit from the top left like the masthead's own ground. The option picked from six.
     any       he fills most of the tile, ears in, the bottom of his fringe running off the edge
     maskable  scaled into the central 80% circle a launcher's mask always keeps */
const ART = join(ROOT, 'tools/art/pinata-full.png');
const PEACH_LIT = '#fbe9d3', PEACH = '#f3cfa6';
const GROUND = 'peach', SHELL = 'peach (maskable fit)';
const ART_B64 = readFileSync(ART).toString('base64');
const ART_ASPECT = 578 / 701;
const browser = await chromium.launch({ executablePath: EXEC });
const S = 512;
const tile = (maskable)=>{
  const w = (maskable ? 0.56 : 0.78) * S, h = w / ART_ASPECT;
  const x = (maskable ? 0.22 : 0.12) * S, y = (maskable ? 0.15 : 0.09) * S;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${S} ${S}">`
    + `<defs><radialGradient id="g" cx="30%" cy="20%" r="110%"><stop offset="0" stop-color="${PEACH_LIT}"/><stop offset="1" stop-color="${PEACH}"/></radialGradient></defs>`
    + `<rect width="${S}" height="${S}" fill="url(#g)"/>`
    + `<image href="data:image/png;base64,${ART_B64}" x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${w.toFixed(1)}" height="${h.toFixed(1)}"/></svg>`;
};
async function png(svg, size) {
  const p = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
  await p.setContent(`<style>html,body{margin:0;background:${PEACH}}svg{width:${size}px;height:${size}px;display:block}</style>${svg}`);
  await p.waitForTimeout(250);
  const buf = await p.screenshot({ omitBackground: false });
  await p.close();
  return buf;
}
const anyPng = await png(tile(false), 512);
const maskPng = await png(tile(true), 512);
// iOS's Add to Home Screen reads a real file at 180, and rounds the corners itself.
const touchPng = await png(tile(false), 180);
// The iPhone app's one 1024 icon; Xcode makes the rest. Opaque: the App Store refuses alpha.
const appIconPng = await png(tile(false), 1024);
// The tab favicon stays inline.
const b32 = (await png(tile(false), 32)).toString('base64');
await browser.close();

/* One stamp for every icon URL, taken from the art itself rather than from a counter someone
   has to remember to turn. Same drawing, same stamp, no churn in the diff; different drawing,
   different URL, and the phone has to go and fetch it. Which is the actual problem: the icons
   live at fixed names, Pages serves them with a max-age, and iOS holds a home-screen icon
   harder than that — so new bytes at an old URL is a change nobody sees. */
const STAMP = createHash('sha1').update(anyPng).update(maskPng).digest('hex').slice(0, 8);
writeFileSync(join(ROOT, 'icon-512.png'), anyPng);
writeFileSync(join(ROOT, 'icon-512-maskable.png'), maskPng);
writeFileSync(join(ROOT, 'apple-touch-icon.png'), touchPng);
const IOS_ICON = join(ROOT, 'ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png');
if (existsSync(dirname(IOS_ICON))) writeFileSync(IOS_ICON, appIconPng);

const file = join(ROOT, 'index.html');
let html = readFileSync(file, 'utf8');
const before = html.length;
const links = [
  // Matches both spellings — the data: URI this replaces, and the stamped file it becomes —
  // so the rewrite is idempotent and this script stays re-runnable.
  [/<link rel="apple-touch-icon"[^>]*>/,
   `<link rel="apple-touch-icon" sizes="180x180" href="apple-touch-icon.png?v=${STAMP}">`],
  [/<link rel="icon" type="image\/png"(?: sizes="32x32")? href="data:image\/png;base64,[A-Za-z0-9+/=]+">/,
   `<link rel="icon" type="image/png" sizes="32x32" href="data:image/png;base64,${b32}">`],
  // The manifest is stamped too, or the phone reads a cached copy that still names the old
  // icon URLs and the stamp on those buys nothing.
  [/<link rel="manifest" href="manifest\.webmanifest[^"]*">/,
   `<link rel="manifest" href="manifest.webmanifest?v=${STAMP}">`],
];
for (const [re, out] of links) {
  if (!re.test(html)) throw new Error(`inline icon link not found: ${re}`);
  html = html.replace(re, out);
}
writeFileSync(file, html);

const mf = join(ROOT, 'manifest.webmanifest');
let json = readFileSync(mf, 'utf8');
const SRC_RE = /"src":\s*"(icon-512(?:-maskable)?\.png)[^"]*"/g;
// Tested for a match, not for a change: art that has not changed stamps the same value, which
// leaves the file identical and is not the same thing as finding nothing to stamp.
if (!SRC_RE.test(json)) throw new Error('no icon src found in the manifest to stamp');
SRC_RE.lastIndex = 0;
const stamped = json.replace(SRC_RE, `"src": "$1?v=${STAMP}"`);
JSON.parse(stamped);   // a manifest that does not parse installs nothing at all
writeFileSync(mf, stamped);
console.log(`v=${STAMP} · icon-512.png ${anyPng.length}B on ${GROUND} · icon-512-maskable.png `
          + `${maskPng.length}B on ${SHELL} · apple-touch-icon.png ${touchPng.length}B · inline 32 `
          + `· index.html ${before} -> ${html.length}`);
