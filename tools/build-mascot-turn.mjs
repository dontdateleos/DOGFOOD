/* Cuts the piñata's turnaround sheet into the frames the mascot turns through.
 *
 *   node tools/build-mascot-turn.mjs
 *
 * Reads tools/art/pinata-turnaround.png (a 5x3 sheet of the same piñata from fifteen angles on
 * a peach ground, labels under each) and writes mascot/turn/<name>.webp plus
 * mascot/turn/frames.json. Every frame comes out on ONE canvas size with the middle of his
 * blue bottom fringe at the bottom centre, so swapping frames turns him on the spot instead of
 * jumping, and a mirrored frame is a plain flip about the centre. frames.json is the eye in
 * each frame (where the white of it is, as a fraction of the canvas), so lids can land on it;
 * its contents are pasted into PINATA.frames in index.html.
 */
import { chromium } from 'playwright';
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const EXEC = process.env.CHROME || '/opt/pw-browsers/chromium';
const OUT = join(ROOT, 'mascot', 'turn');
mkdirSync(OUT, { recursive: true });
const NAMES = [['fl34','front','fr34','right','br34'],['left','bl34','back','top','bottom'],['low','high','topfront','topback','tilt']];
const ROWS = [[8, 302], [336, 622], [676, 964]];
// The frames the mascot uses. The others on the sheet are mislabelled or repeats.
const USE = ['front', 'fl34', 'left', 'bl34', 'back', 'high', 'low', 'top', 'bottom'];
// Where the white of the eye detection misses part of it (looked at, by hand), in sheet-cell px.
const EYE_FIX = { high: [190, 123, 236, 178], low: [196, 83, 238, 128] };
const HEIGHT = 240;

const b = await chromium.launch({ executablePath: EXEC });
const p = await b.newPage();
const src = 'data:image/png;base64,' + readFileSync(join(ROOT, 'tools/art/pinata-turnaround.png')).toString('base64');
const out = await p.evaluate(async ({ src, NAMES, ROWS, USE, EYE_FIX, HEIGHT })=>{
  const img = new Image(); img.src = src; await img.decode();
  const cut = [];
  for(let r = 0; r < 3; r++) for(let col = 0; col < 5; col++){
    const name = NAMES[r][col]; if(!USE.includes(name)) continue;
    const X = Math.round(col * 307.2), W = 307, Y = ROWS[r][0], H = ROWS[r][1] - ROWS[r][0];
    const c = document.createElement('canvas'); c.width = W; c.height = H;
    const g = c.getContext('2d'); g.drawImage(img, X, Y, W, H, 0, 0, W, H);
    const id = g.getImageData(0, 0, W, H), d = id.data;
    const chroma = i=>{ const mx = Math.max(d[i], d[i+1], d[i+2]), mn = Math.min(d[i], d[i+1], d[i+2]); return [mx, mx - mn]; };
    // The ground: bright, warm, low chroma. Flood it in from the edges.
    const isBg = i=>{ const [mx, ch] = chroma(i); return mx > 150 && ch < 75 && d[i] >= d[i+1] && d[i+1] >= d[i+2] - 6 && !(d[i] > 240 && d[i+1] > 240 && d[i+2] > 235); };
    // His floor shadow: dull tan, under him. Lower and darker than the ground, so its own test.
    const isShadow = i=>{ const [mx, ch] = chroma(i); return mx > 70 && ch < 0.5 * mx && d[i] >= d[i+2]; };
    const bg = new Uint8Array(W*H), q = [];
    const push = (x, y, test)=>{ const k = y*W + x; if(bg[k] || !test(k*4)) return; bg[k] = 1; q.push([k, test]); };
    for(let x = 0; x < W; x++){ push(x, 0, isBg); push(x, H-1, isBg); } for(let y = 0; y < H; y++){ push(0, y, isBg); push(W-1, y, isBg); }
    while(q.length){ const [k, t] = q.pop(), x = k % W, y = (k / W) | 0; if(x > 0) push(x-1, y, t); if(x < W-1) push(x+1, y, t); if(y > 0) push(x, y-1, t); if(y < H-1) push(x, y+1, t); }
    // Then the shadow, flooded from the ground it touches, in the bottom of the cell only.
    const low = H - 70;
    for(let k = 0; k < W*H; k++){ if(!bg[k]) continue; const x = k % W, y = (k / W) | 0; if(y < low) continue;
      for(const [a, bq] of [[x-1,y],[x+1,y],[x,y-1],[x,y+1]]){ if(a < 0 || bq < low || a >= W || bq >= H) continue; const m = bq*W + a; if(!bg[m] && isShadow(m*4)){ bg[m] = 1; q.push([m, isShadow]); } } }
    while(q.length){ const [k, t] = q.pop(), x = k % W, y = (k / W) | 0; for(const [a, bq] of [[x-1,y],[x+1,y],[x,y-1],[x,y+1]]){ if(a < 0 || bq < low || a >= W || bq >= H) continue; const m = bq*W + a; if(!bg[m] && t(m*4)){ bg[m] = 1; q.push([m, t]); } } }
    // Keep the largest piece left.
    const lab = new Int32Array(W*H); let best = 0, bestN = 0, n = 0;
    for(let k = 0; k < W*H; k++){ if(bg[k] || lab[k]) continue; n++; let cnt = 0; const st = [k]; lab[k] = n;
      while(st.length){ const j = st.pop(); cnt++; const x = j % W, y = (j / W) | 0; for(const [a, bq] of [[x-1,y],[x+1,y],[x,y-1],[x,y+1]]){ if(a < 0 || bq < 0 || a >= W || bq >= H) continue; const m = bq*W + a; if(!bg[m] && !lab[m]){ lab[m] = n; st.push(m); } } }
      if(cnt > bestN){ bestN = cnt; best = n; } }
    const A = new Uint8Array(W*H); for(let k = 0; k < W*H; k++) A[k] = lab[k] === best ? 1 : 0;
    let x0 = W, y0 = H, x1 = 0, y1 = 0;
    for(let y = 0; y < H; y++) for(let x = 0; x < W; x++){ const k = y*W + x;
      let a = 0; if(A[k]){ let s = 0, cn = 0; for(let dy = -1; dy <= 1; dy++) for(let dx = -1; dx <= 1; dx++){ const aa = x+dx, bb = y+dy; cn++; if(aa >= 0 && bb >= 0 && aa < W && bb < H) s += A[bb*W + aa]; } a = s / cn < 0.7 ? 0.55 : 1; }
      d[k*4+3] = Math.round(a * 255); if(a > 0){ x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); } }
    g.putImageData(id, 0, 0);
    // Anchor: the middle of the blue fringe along his bottom edge.
    let bx = 0, bn = 0; for(let y = Math.max(y0, y1 - 30); y <= y1; y++) for(let x = x0; x <= x1; x++){ const k = y*W + x; if(!A[k]) continue; const i = k*4; if(d[i+2] > 170 && d[i] < 120){ bx += x; bn++; } }
    const ax = bn ? bx / bn : (x0 + x1) / 2;
    // The eye: the white blobs inside him, the biggest plus any touching its box.
    let eye = EYE_FIX[name] || null;
    if(!eye){
      const wl = new Int32Array(W*H), blobs = []; let wn = 0;
      const white = k=>{ const i = k*4; return A[k] && d[i] > 215 && d[i+1] > 210 && d[i+2] > 200 && chroma(i)[1] < 40; };
      for(let k = 0; k < W*H; k++){ if(wl[k] || !white(k)) continue; wn++; const st = [k]; wl[k] = wn; let cnt = 0, e = [W, H, 0, 0];
        while(st.length){ const j = st.pop(); cnt++; const x = j % W, y = (j / W) | 0; e = [Math.min(e[0], x), Math.min(e[1], y), Math.max(e[2], x), Math.max(e[3], y)];
          for(const [a, bq] of [[x-1,y],[x+1,y],[x,y-1],[x,y+1]]){ if(a < 0 || bq < 0 || a >= W || bq >= H) continue; const m = bq*W + a; if(!wl[m] && white(m)){ wl[m] = wn; st.push(m); } } }
        if(cnt > 25) blobs.push({ e, n: cnt }); }
      blobs.sort((a, b2)=> b2.n - a.n);
      if(blobs.length && blobs[0].n > 300){
        eye = blobs[0].e.slice();
        for(const o of blobs.slice(1)) if(o.e[0] < eye[2] + 4 && o.e[2] > eye[0] - 4 && o.e[1] < eye[3] + 12)
          eye = [Math.min(eye[0], o.e[0]), Math.min(eye[1], o.e[1]), Math.max(eye[2], o.e[2]), Math.max(eye[3], o.e[3])];
      }
    }
    cut.push({ name, c, x0, y0, x1, y1, ax, ay: y1, eye });
  }
  // One canvas for all: wide enough for the widest side of any frame either way (so mirrors fit).
  const half = Math.max(...cut.map(o=> Math.max(o.ax - o.x0, o.x1 - o.ax))) + 2;
  const tall = Math.max(...cut.map(o=> o.ay - o.y0)) + 3;
  const k = HEIGHT / tall, CW = Math.round(2 * half * k), CH = HEIGHT;
  const frames = {}, files = {};
  for(const o of cut){
    const t = document.createElement('canvas'); t.width = CW; t.height = CH;
    const tg = t.getContext('2d'); tg.imageSmoothingQuality = 'high';
    const ox = CW / 2 - o.ax * k, oy = CH - 1 - o.ay * k;
    tg.drawImage(o.c, ox, oy, o.c.width * k, o.c.height * k);
    files[o.name] = t.toDataURL('image/webp', 0.9);
    const e = o.eye;
    frames[o.name] = e ? { eye: [((e[0] + e[2]) / 2 * k + ox) / CW, ((e[1] + e[3]) / 2 * k + oy) / CH, ((e[2] - e[0]) / 2 + 1.5) * k / CW, ((e[3] - e[1]) / 2 + 1.5) * k / CH].map(v=> +v.toFixed(4)) } : {};
  }
  return { CW, CH, frames, files };
}, { src, NAMES, ROWS, USE, EYE_FIX, HEIGHT });
for(const [n, url] of Object.entries(out.files)) writeFileSync(join(OUT, n + '.webp'), Buffer.from(url.split(',')[1], 'base64'));
writeFileSync(join(OUT, 'frames.json'), JSON.stringify({ w: out.CW, h: out.CH, frames: out.frames }, null, 1) + '\n');
console.log(JSON.stringify({ w: out.CW, h: out.CH, frames: out.frames }));
await b.close();
