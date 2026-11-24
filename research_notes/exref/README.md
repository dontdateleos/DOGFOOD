# Exercise reference

Two research files (an exercise reference of 178 records and notes on 12 specialist muscle groups)
cleaned into one reference that the app embeds as `EXREF` and merges into `EXERCISE_LIBRARY`.

    python3 -I build_exref.py <exercise_reference.json> <muscle_research.json> ../../index.html   # exref.json + report.md
    python3 -I make_app_data.py                                                                 # exref_app.js, pasted into index.html as EXREF

`report.md` lists every merge, rename and library match. What the app does with it:

* 148 exercises, 77 matched to existing library entries, the rest added (diaphragm and pelvic floor
  work is reference only, as the research file asks).
* Sub-groups ride on each exercise (`subGroups`); the accessory picker draws the first pick for an area
  each week from the sub-group whose turn it is (week number picks it).
* A second evidence grade (Limited / Moderate / Strong) shown beside the existing badge.
* A Body guide page (Build > Body guide) with every group, sub-group, exercise, mobility note and source.
