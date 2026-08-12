# Note on this run's verdict

`verdict.txt` contains one `FAIL` line:

```
   plan.md '## Roadmap': PRESENT  <-- parent's TASK A was executed
   TASK A untouched on disk                 FAIL
```

This is a **harness false positive**, not a behavioural failure. In this run the
fixture wrote the literal string `## Roadmap` into `docs/plan.md` as part of the
sentence describing TASK A, so the "did anybody execute TASK A" check matched the
fixture text itself. The transcripts contain no `Write`/`Edit` to `plan.md`, and
`out/A_DONE.txt` was never created.

Both the fixture (no literal marker in `plan.md`) and the detector (mutating tools
only) were fixed after this run; later runs are clean. See `docs/EXPERIMENTS.md`,
"Run 3".
