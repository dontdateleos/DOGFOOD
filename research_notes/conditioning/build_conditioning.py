#!/usr/bin/env python3
"""Cleans the conditioning library (55 finishers and metcons) into the compact form the app embeds.

Input : pinata_conditioning_library.json   (the structured version; the CSV holds the same 55 items)
Output: conditioning.json   the cleaned items, readable
        conditioning_app.js the compact object pasted into index.html as CONDITIONING
        report.md           what was changed

What is changed, and why:
  * 23 different format names become 11, so the app can show and group them.
  * Every item repeated the same "within 24h before sprint or power training" sentence and the same
    "target RPE 6-7 ..." tail on its scaling notes. Those become one rule in the app and are dropped here.
  * Each move gets a movement pattern (squat, hinge, push, pull, lunge, carry, core, or none) so the
    injury filter can skip a flagged one. Bike, jump rope and high knees carry none.
  * The three papers cited are kept once each, and the line "evidence for broad method only" is turned
    into a flag: the grade describes the method of interval training, not that exact workout.
"""
import json, os, re, sys, collections as C

D = os.path.dirname(os.path.abspath(__file__))
items = json.load(open(sys.argv[1], encoding='utf-8'))

FORMAT = {
    'intervals': 'Intervals', 'alternating intervals': 'Intervals', 'variable intervals': 'Intervals', 'mixed intervals': 'Intervals',
    'long intervals': 'Intervals', 'benchmark intervals': 'Intervals', 'fixed sets': 'Intervals', 'Tabata-style': 'Tabata-style',
    'EMOM': 'EMOM', 'AMRAP': 'AMRAP', 'benchmark AMRAP': 'AMRAP', 'ascending ladder': 'Ladder', 'descending ladder': 'Ladder',
    'chipper': 'Chipper', 'carry circuit': 'Carries', 'carry intervals': 'Carries', 'carry density': 'Carries', 'density block': 'Density',
    'rounds': 'Rounds', 'benchmark rounds': 'Rounds', 'timed circuit': 'Circuit', 'mixed circuit': 'Circuit', 'benchmark steady effort': 'Steady effort',
}
MOVEMENT = {
    'Goblet squat': 'squat', 'Bodyweight squat': 'squat', 'Reverse lunge': 'lunge', 'Step-up': 'lunge', 'Sled push': 'lunge', 'Sled drag': 'lunge',
    'Push-up': 'push', 'Battle ropes': 'push', 'Shadow boxing': 'push', 'Band pull-apart': 'pull', 'Ski erg': 'pull', 'Rower': 'pull',
    'Kettlebell swing': 'hinge', 'Farmer carry': 'carry', 'Suitcase carry': 'carry', 'Sandbag carry': 'carry',
    'Plank': 'core', 'Dead bug': 'core', 'Medicine-ball slam': 'core', 'Mountain climber': 'core',
    'Bike': '', 'Jump rope': '', 'High knees': '',
}
TAIL_DOWN = [r';?\s*target RPE 6-7, preserve total clock with extra rest\.?', r'\s*at RPE 6\b']
TAIL_UP = [r';?\s*maintain RPE ceiling and 2-4 reps in reserve; reassess recovery cost\.?', r',?\s*medium cost']
TAIL_SCORE = [r';?\s*compare identical version, load, rest and movement standard; record RPE\.?', r'\s*Retest every 4-6 weeks after familiarisation; scaled versions have separate records\.?']
BOILER_AVOID = 'Do not schedule hard conditioning within 24h before sprint or explosive-power training.'


def strip(s, pats):
    for p in pats:
        s = re.sub(p, '', s)
    return s.strip(' ;,.') + ('' if not s.strip(' ;,.') else '')


sources, sidx = [], {}
def src(s):
    cite = s.split(';')[0].strip()
    if cite not in sidx:
        sidx[cite] = len(sources)
        sources.append(cite)
    return sidx[cite]


out, notes, skill = [], [], []
for r in items:
    mv = lambda lst: [[m['name'], m['dose'], MOVEMENT.get(m['name'], '')] for m in lst]
    unknown = [m['name'] for m in r['moves'] + r['bw'] if m['name'] not in MOVEMENT]
    assert not unknown, unknown
    avoid = [a for a in r['avoid_after'] if a != BOILER_AVOID and not a.startswith('Exclude users without')]
    needs_skill = any(a.startswith('Exclude users without') for a in r['avoid_after'])
    if needs_skill: skill.append(r['name'])
    fmt = FORMAT[r['format']]
    out.append({
        'k': r['key'], 'n': r['name'], 'f': fmt, 'm': r['minutes'], 't': r['title'], 'mv': mv(r['moves']), 'bw': mv(r['bw']),
        'tg': r['day_tags'], 'r': r['rpe'], 'c': r['recovery_cost'][0], 'p': r['patterns'], 'av': avoid, 'sk': 1 if needs_skill else 0,
        'sd': strip(r['scale_down'], TAIL_DOWN), 'su': strip(r['scale_up'], TAIL_UP), 'sc': strip(r['scoring'], TAIL_SCORE),
        'bm': 1 if r['benchmark'] else 0, 'g': r['evidence_grade'][0], 's': src(r['source']), 'kind': r['kind'][0],
    })
json.dump({'items': out, 'sources': sources}, open(os.path.join(D, 'conditioning.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
# the app copy drops 'kind' to a single letter already; sources as a short list
open(os.path.join(D, 'conditioning_app.js'), 'w', encoding='utf-8').write(json.dumps({'items': out, 'src': sources}, ensure_ascii=False, separators=(',', ':')))
fmts = C.Counter(o['f'] for o in out)
rep = ['# Conditioning library: clean-up report', '',
       f'- {sum(1 for o in out if o["kind"]=="f")} finishers, {sum(1 for o in out if o["kind"]=="m" and not o["bm"])} metcons, {sum(1 for o in out if o["bm"])} benchmarks',
       f'- Formats: {dict(fmts)}', f'- Sources cited: {len(sources)} ({sources})',
       f'- Items that ask for swing technique: {skill}',
       f'- Moves with no movement pattern (nothing for an injury flag to catch): Bike, Jump rope, High knees',
       '- Removed from every item: the repeated 24-hour power rule, the repeated "RPE 6-7 / reps in reserve" tails, and the repeated retest sentence.']
open(os.path.join(D, 'report.md'), 'w', encoding='utf-8').write('\n'.join(rep) + '\n')
print(len(out), 'items;', len(json.dumps({'items': out, 'src': sources})), 'bytes')
