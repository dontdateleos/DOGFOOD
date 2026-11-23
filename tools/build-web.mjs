/* Copies the web app into www/, the folder Capacitor bundles into the iPhone app.
   The app is one file plus its icons, manifest, service worker and launch images; everything
   else in the repo (tools, spec, the native project itself) stays out of the bundle.
   Run: node tools/build-web.mjs   (or npm run ios:sync, which also copies it into Xcode) */
import { cpSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'www');
const FILES = ['index.html', 'sw.js', 'manifest.webmanifest', 'icon-512.png', 'icon-512-maskable.png', 'apple-touch-icon.png'];
const DIRS = ['splash', 'mascot', 'shell'];

rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
for (const f of FILES) if (existsSync(join(ROOT, f))) cpSync(join(ROOT, f), join(OUT, f));
for (const d of DIRS) if (existsSync(join(ROOT, d))) cpSync(join(ROOT, d), join(OUT, d), { recursive: true });
console.log('www/ built:', [...FILES, ...DIRS].filter(f => existsSync(join(ROOT, f))).join(', '));
