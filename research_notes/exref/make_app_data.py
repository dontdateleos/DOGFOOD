#!/usr/bin/env python3
"""Turns exref.json into the compact object the app embeds as EXREF (written to exref_app.js)."""
import json, os, re
D = os.path.dirname(os.path.abspath(__file__))
x = json.load(open(os.path.join(D, 'exref.json'), encoding='utf-8'))
sources, sidx = [], {}
def src(s):
    if s not in sidx: sidx[s] = len(sources); sources.append(s)
    return sidx[s]
EQ = {'bands': 'band', 'pull-up bar': 'pull_up_bar', 'medicine ball': 'medicine_ball', 'weights': 'plate', 'bar': 'barbell', 'anchor': 'other',
      'inspiratory trainer': 'other'}
ex = []
for e in x['exercises']:
    ex.append({'id': e['id'], 'n': e['name'], 'eq': sorted({EQ.get(q, q) for q in e['equipment']}), 'd': e['difficulty'][0],  # b / i / a
               'sec': e['secondary'], 'home': e['home'], 'lib': e['libraryId'],
               't': [[t['group'], t['area'], t['sub'], t['goal'], t['grade'][0], t['sets'], t['reps'], t['rir'], t['rest'], t['note'], src(t['source']), 1 if t['auto'] else 0] for t in e['targets']]})
notes = {g: {'rom': n['rom'], 'mob': n['mobility'], 'wu': n['warmup'], 'lim': n['limits'], 's': src(n['source']), 'no': n['unsupported']} for g, n in x['groupNotes'].items()}
drills = [{'g': d['group'], 'n': d['name'], 't': d['note'], 'gr': d['grade'][0], 's': src(d['source'])} for d in x['drills']]
gm = x['generalMobility']; gm = {'static': gm['static'], 'dynamic': gm['dynamic'], 'pnf': gm['pnf'], 'evidence': gm['evidence'], 's': src(gm['source'])}
tax = {g: [v['area'], v['sub'], 1 if v['auto'] else 0] for g, v in x['taxonomy'].items()}
out = {'src': sources, 'tax': tax, 'gm': gm, 'notes': notes, 'drills': drills, 'ex': ex}
js = json.dumps(out, ensure_ascii=False, separators=(',', ':'))
open(os.path.join(D, 'exref_app.js'), 'w', encoding='utf-8').write(js)
print(len(js), 'bytes;', len(ex), 'exercises;', len(sources), 'sources')
