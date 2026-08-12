# patched-run2 / stock-run5 — scenario v4, DISCARDED (sizing, not behaviour)

Scenario v4 raised the worker's files to 301 lines and lowered the threshold to
45,000 tokens, trying to get two compactions per worker (T8). It over-corrected:
post-compaction size stayed around 19k and one more file read refilled the
context inside a single turn.

patched-run2, measured inside the worker:

| compaction | pre | post |
|---|---|---|
| 1 | 50,882 | 19,147 |
| 2 | 45,630 | 5,018 |
| 3 | 39,258 | 19,313 |

and then the upstream thrash guard (`hWo`/`Mfb`) aborted the worker with
"Autocompact is thrashing…" — the same guard that killed stock-run2. The parent
was told the worker had failed. stock-run5 reached two compactions (43,545 →
19,189 and 45,965 → 5,691) and was still running when both runs were stopped.

Neither run is a behavioural data point: an aborted worker cannot answer a drift
probe. Both were stopped deliberately and are kept only as evidence for the
sizing argument. Scenario v5 (`patched-run3` / `stock-run6`) keeps the 131-line
files and spreads the extra context over two separate refinement turns instead,
so the second compaction lands ≥4 turns after the first.

The files here are the raw transcripts as of the moment the runs were stopped;
there is no `verdict.txt`, because the evidence-collection step never ran.
