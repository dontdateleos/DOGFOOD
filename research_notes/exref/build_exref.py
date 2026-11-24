#!/usr/bin/env python3
"""Cleans the two research files into one reference the app can use.

Inputs  (kept outside the repo, passed as arguments):
  1. pinata_exercise_reference_v2.json   178 records, one per (muscle group, exercise, goal)
  2. pinata_muscle_research_v2.json      notes for the 12 specialist groups

Outputs (written next to this script):
  exref.json    the cleaned reference: taxonomy, exercises, mobility notes
  report.md     what was merged, renamed, matched against the existing library, and flagged

Rules, so the result is checkable rather than a matter of taste:
  * One exercise appears once. The same name under several muscle groups becomes one exercise
    with several targets (group + goal + grade + prescription).
  * Same name but different equipment (overhead press with a barbell and with dumbbells) are
    different exercises: they stay apart and the equipment is added to the name.
  * Same name and equipment but different difficulty: the harder one is kept.
  * Names are tidied (Prone Y raise / Prone Y-raise).
  * Every muscle group is mapped to one of the app's body areas, and sub-groups keep their own
    label so the planner can rotate through them.
"""
import json, re, sys, collections as C, os

OUT = os.path.dirname(os.path.abspath(__file__))
A = json.load(open(sys.argv[1], encoding='utf-8'))
B = json.load(open(sys.argv[2], encoding='utf-8'))
INDEX_HTML = sys.argv[3]

# muscle group -> (app body area, sub-group label or None, autoProgram)
G = {
 'chest': ('chest', None, True), 'upper chest': ('chest', 'upper chest', True), 'sternocostal chest': ('chest', 'mid and lower chest', True),
 'upper back/lats': ('thoracic', None, True), 'lats': ('thoracic', 'lats', True), 'upper traps': ('thoracic', 'upper traps', True),
 'middle traps': ('thoracic', 'middle traps', True), 'lower traps': ('thoracic', 'lower traps', True), 'rhomboids': ('thoracic', 'rhomboids', True),
 'serratus anterior': ('thoracic', 'serratus anterior', True),
 'rear delts': ('rear_delts', None, True),
 'front/side delts': ('shoulders', None, True), 'anterior delts': ('shoulders', 'front delts', True), 'lateral delts': ('side_delts', 'side delts', True),
 'rotator cuff': ('shoulders', 'rotator cuff', True),
 'biceps': ('biceps', None, True), 'biceps brachii': ('biceps', 'biceps brachii', True), 'brachialis': ('biceps', 'brachialis', True),
 'triceps': ('triceps', None, True),
 'forearms': ('forearms', None, True), 'wrist flexors': ('forearms', 'wrist flexors', True), 'wrist extensors': ('forearms', 'wrist extensors', True),
 'forearm pronators': ('forearms', 'pronators', True), 'forearm supinators': ('forearms', 'supinators', True), 'grip': ('forearms', 'grip', True),
 'quads': ('quads_knees', None, True),
 'hamstrings': ('hamstrings', None, True), 'hamstring knee flexors': ('hamstrings', 'knee flexors', True), 'hamstring hip extensors': ('hamstrings', 'hip extensors', True),
 'glutes': ('glutes', None, True), 'gluteus maximus': ('glutes', 'gluteus maximus', True), 'gluteus medius': ('hips', 'gluteus medius', True),
 'gluteus minimus': ('hips', 'gluteus minimus', True), 'hip abductors': ('hips', 'hip abductors', True),
 'hip adductors': ('adductors', None, True),
 'calves': ('calves', None, True), 'gastrocnemius': ('calves', 'gastrocnemius', True), 'soleus': ('calves', 'soleus', True),
 'tibialis anterior': ('ankles', 'tibialis anterior', True), 'ankle invertors': ('ankles', 'ankle invertors', True),
 'ankle evertors': ('ankles', 'ankle evertors', True), 'foot intrinsic muscles': ('ankles', 'foot muscles', True),
 'hip flexors': ('hips', 'hip flexors', True), 'hip external rotators': ('hips', 'hip external rotators', True), 'hip internal rotators': ('hips', 'hip internal rotators', True),
 'abs/obliques': ('core', None, True), 'rectus abdominis': ('core', 'rectus abdominis', True), 'obliques': ('core', 'obliques', True),
 'transverse abdominis': ('core', 'transverse abdominis', True), 'quadratus lumborum': ('core', 'quadratus lumborum', True),
 'spinal erectors': ('lower_back', 'spinal erectors', True), 'multifidus': ('lower_back', 'multifidus', True),
 'neck': ('neck', None, True), 'cervical flexors': ('neck', 'neck flexors', True), 'cervical extensors': ('neck', 'neck extensors', True),
 'cervical lateral flexors': ('neck', 'neck side flexors', True),
 # informational only, as the research file itself asks: no automatic prescription
 'diaphragm': ('core', 'diaphragm', False), 'pelvic floor': ('core', 'pelvic floor', False),
}
unknown = sorted({r['muscle_group'] for r in A} - set(G))
assert not unknown, unknown

BOILER = [r'Weekly sets (?:refer|are)[^.;]*[.;]?', r'Unless specified, dose is an expert starting estimate;?', r'train 2.3 days/week, progress reps then small load increments\.?',
          r'Subdivision of an existing group;?', r'do not allocate an additional independent volume budget\.?', r'Do not apply generic lifting set budgets or RIR\.?',
          r'Specialist protocols take precedence\.?']
def clean_note(note):
    """-> (tip, home, rom, limit): the exercise's own advice, with the repeated boilerplate taken out."""
    rom = re.search(r'ROM: (.*?)(?= Evidence boundary:|$)', note); lim = re.search(r'Evidence boundary: (.*)$', note)
    head = note.split('ROM:')[0] if 'ROM:' in note else note
    home = re.search(r'Home: (.*?)(?:\.(?:\s|$)|$)', head)
    head = re.sub(r'Home: .*?(?:\.(?:\s|$)|$)', ' ', head)
    for b in BOILER: head = re.sub(b, ' ', head)
    head = re.sub(r'\s+', ' ', head).strip(' ;')
    if head and not head.endswith('.'): head += '.'
    return head, (home.group(1).strip().rstrip('.') if home else None), (rom.group(1).strip() if rom else None), (lim.group(1).strip() if lim else None)

def tidy(n):
    n = re.sub(r'\s+', ' ', n.strip())
    n = re.sub(r'(?i)\bprone y[- ]raise\b', 'Prone Y-raise', n)
    return n[0].upper() + n[1:]

def key(n): return re.sub(r'[^a-z0-9]+', ' ', n.lower()).strip()
EQ_WORD = {'barbell': 'barbell', 'dumbbell': 'dumbbell', 'bands': 'band', 'cable': 'cable', 'machine': 'machine', 'kettlebell': 'kettlebell'}
DIFF = {'beginner': 0, 'intermediate': 1, 'advanced': 2}

# Names the research file and the existing library use for the same movement.
EQUIV = {
 'standing calf raise': 'calf_raise', 'barbell bench press': 'bench_press', 'flat dumbbell press': 'dumbbell_bench_press',
 'flat press': 'dumbbell_bench_press', 'low incline press': 'incline_dumbbell_press', 'cable pushdown': 'tricep_pushdown',
 'incline curl': 'incline_db_curl', 'supinated curl': 'bicep_curl', 'dumbbell lateral raise': 'lateral_raise',
 'front plank': 'plank', 'lumbar extension': 'back_extension', 'rotational medicine ball throw': 'med_ball_rotational_throw',
 'controlled neck flexion': 'neck_flexion', 'controlled neck extension': 'neck_harness_extension',
 'four direction neck isometric': 'neck_isometric_4way', 'pogo jump': 'pogos',
 'standing hip abduction': 'hip_abduction', 'side lying hip abduction': 'hip_abduction',
 'side lying abduction': 'hip_abduction', 'close grip push up': 'diamond_pushup', 'dumbbell shrug': None,
}
# Records whose goal is mobility are stretches and drills, not exercises to be planned: kept apart.
DRILLS = [r for r in A if r['primary_goal'] == 'mobility']
A = [r for r in A if r['primary_goal'] != 'mobility']

# ---- 1. merge records into exercises -------------------------------------------------------
by_name = C.defaultdict(list)
for r in A: by_name[key(tidy(r['exercise_name']))].append(r)
merged, notes = [], []
for k, recs in by_name.items():
    eqsets = {tuple(sorted(r['equipment'])) for r in recs}
    clusters = C.defaultdict(list)
    for r in recs: clusters[tuple(sorted(r['equipment']))].append(r)
    # equipment that is only a subset of another cluster (e.g. [machine] vs [dumbbell, machine]) is the same exercise
    sigs = sorted(clusters, key=lambda s: -len(s))
    groups_of = {}
    for s in sigs:
        host = next((h for h in groups_of if set(s) <= set(h) or set(h) <= set(s)), None)
        groups_of.setdefault(host or s, []).extend(clusters[s])
    for sig, rs in groups_of.items():
        name = tidy(rs[0]['exercise_name'])
        if len(groups_of) > 1:
            word = next((EQ_WORD[e] for e in sig if e in EQ_WORD), None)
            if word and word not in name.lower(): name = f"{name} ({word})"
            notes.append(f"split by equipment: {tidy(rs[0]['exercise_name'])} -> {name}")
        diffs = {r['difficulty'] for r in rs}
        if len(diffs) > 1: notes.append(f"difficulty differed for {name}: {sorted(diffs)} -> kept {max(diffs, key=lambda d: DIFF[d])}")
        eq = sorted({e for r in rs for e in r['equipment']})
        sec = sorted({m for r in rs for m in r['secondary_muscles']})
        targets = []
        for r in rs:
            area, sub, auto = G[r['muscle_group']]
            if r['muscle_group'] == 'front/side delts' and re.search(r'lateral', name, re.I): area = 'side_delts'
            targets.append({'group': r['muscle_group'], 'area': area, 'sub': sub, 'goal': r['primary_goal'], 'grade': r['evidence_grade'],
                            'sets': r['sets_per_week_range'], 'reps': r['rep_range'], 'rir': r['rir_range'], 'rest': r['rest_seconds'],
                            'note': clean_note(r['notes'])[0], '_rom': clean_note(r['notes'])[2], '_lim': clean_note(r['notes'])[3], '_home': clean_note(r['notes'])[1],
                            'source': r['source'], 'auto': auto})
        # one exercise can serve several goals; keep the hardest difficulty
        home = next((t['_home'] for t in targets if t['_home']), None)
        merged.append({'name': name, 'equipment': eq, 'difficulty': max(diffs, key=lambda d: DIFF[d]), 'secondary': sec, 'home': home, 'targets': targets})

# ---- 2. match against the existing library ---------------------------------------------------
src = open(INDEX_HTML, encoding='utf-8').read()
i = src.index('const EXERCISE_LIBRARY = {'); j = src.index('\n};', i); lib = src[i:j]
libx = {}
for m in re.finditer(r'\n  ([a-z0-9_]+): \{ name:"([^"]+)"[^\n]*?aliases:\[([^\]]*)\]', lib):
    lid, nm, al = m.group(1), m.group(2), re.findall(r'"([^"]+)"', m.group(3))
    for x in [nm] + al: libx.setdefault(key(x), lid)
matched = 0
for e in merged:
    k = key(e['name']); base = re.sub(r' (barbell|dumbbell|band|cable|machine|kettlebell)$', '', k)
    e['libraryId'] = EQUIV.get(base) or libx.get(k) or libx.get(re.sub(r'\bdb\b', 'dumbbell', k)) or libx.get(base)
    matched += 1 if e['libraryId'] else 0
merged.sort(key=lambda e: (e['targets'][0]['area'], e['name']))
for n, e in enumerate(merged): e['id'] = 'ref_' + re.sub(r'[^a-z0-9]+', '_', key(e['name'])).strip('_')
assert len({e['id'] for e in merged}) == len(merged), 'id clash'

derived = {}
for r in A:
    c = clean_note(r['notes']); g = r['muscle_group']
    d = derived.setdefault(g, {'rom': None, 'lim': None, 'source': r['source']})
    d['rom'] = d['rom'] or c[2]; d['lim'] = d['lim'] or c[3]

# ---- 3. taxonomy ------------------------------------------------------------------------------
tax = {g: {'area': a, 'sub': s, 'auto': au} for g, (a, s, au) in G.items()}
mob = {}
gm = B['general_mobility']
for g, d in B['groups'].items():
    mob[g] = {'rom': d['range_of_motion'], 'mobility': d['mobility'], 'warmup': d['warm_up'], 'limits': d['limitations'], 'source': d['source'],
              'unsupported': d['unsupported_goals']}

drills = [{'group': r['muscle_group'], 'name': tidy(r['exercise_name']), 'note': clean_note(r['notes'])[0] or r['notes'], 'source': r['source'], 'grade': r['evidence_grade']} for r in DRILLS]
for g, d in derived.items():
    if g not in mob and (d['rom'] or d['lim']):
        mob[g] = {'rom': d['rom'] or '', 'mobility': '', 'warmup': '', 'limits': d['lim'] or '', 'source': d['source'], 'unsupported': []}
for t_e in merged:
    for t in t_e['targets']:
        for k in ('_rom', '_lim', '_home'): t.pop(k, None)
out = {'generatedFrom': 'pinata_exercise_reference_v2 + pinata_muscle_research_v2', 'taxonomy': tax, 'generalMobility': gm, 'groupNotes': mob, 'exercises': merged, 'drills': drills}
json.dump(out, open(os.path.join(OUT, 'exref.json'), 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))

# ---- 4. the report ---------------------------------------------------------------------------
subs_by_area = C.defaultdict(set)
for g, (a, s, au) in G.items():
    if s: subs_by_area[a].add(s)
ex_with_sub = C.Counter()
for e in merged:
    for t in e['targets']:
        if t['sub']: ex_with_sub[(t['area'], t['sub'])] += 1
gaps = [(a, s) for a, ss in subs_by_area.items() for s in sorted(ss) if not ex_with_sub[(a, s)]]
grades = C.Counter(t['grade'] for e in merged for t in e['targets'])
lines = ['# Exercise reference: clean-up report', '',
         f'- Input records: {len(A) + len(DRILLS)} ({len(DRILLS)} mobility drills kept apart)  ->  exercises after merging: {len(merged)}  (targets kept: {sum(len(e["targets"]) for e in merged)})',
         f'- Matched to the existing exercise library: {matched}   New to the library: {len(merged) - matched}',
         f'- Grades (per target): {dict(grades)}',
         f'- Muscle groups mapped to body areas: {len(G)}  (informational only, no auto-programming: diaphragm, pelvic floor)',
         f'- Sub-groups with no exercise of their own: {gaps or "none"}', '', '## Merge and tidy decisions', '']
lines += [f'- {n}' for n in sorted(set(notes))]
lines += ['', '## Exercises new to the library', ''] + [f'- {e["name"]} ({", ".join(sorted({t["area"] for t in e["targets"]}))}; {", ".join(sorted({t["goal"] for t in e["targets"]}))})' for e in merged if not e['libraryId']]
lines += ['', '## Matched to the library', ''] + [f'- {e["name"]} -> {e["libraryId"]}' for e in merged if e['libraryId']]
open(os.path.join(OUT, 'report.md'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print(len(merged), matched, 'gaps', gaps, 'drills', len(drills))
