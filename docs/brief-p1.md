# Phase 1 — take the response sweep off the drag path

You are working in `/home/creolben/Projects/omarchy-equalizer-pr4` (git branch
`pr-4-audit`). This is an Omarchy shell plugin: a QML panel (`Panel.qml`,
`ResponseCurve.qml`, `Model.js`) over a bash backend (`bin/omarchy-equalizer`)
that drives a PipeWire filter chain.

Read `docs/spec-v2.md` §1.2, §2 and §3 first. This brief is Phase 1 of that
spec: a pure performance change. **No user-visible behaviour may change.**

## The working tree is already dirty on purpose

`git status` shows modified `README.md` and `ResponseCurve.qml`, plus untracked
`presets/Zouk.json`, `presets/Kompa.json`, `docs/spec-v2.md`. These are correct
work from another session. **Do not revert, reformat, or "clean up" any of
them.** Do not commit, stage, or create branches. `ResponseCurve.qml` should not
be touched at all in this phase.

## The problem

`Model.peakDb(bands, preamp, rate)` (`Model.js`) walks 401 frequency points and
calls `responseDb` per point, which rebuilds every band's coefficients per
point — 4010 biquad coefficient builds for ten bands. Measured on this machine:
11.9 ms per call. `Model.autoPreampDb` is another 11.8 ms. The panel reads
`Model.peakDb` from three bindings and `Model.autoPreampDb` from one
(`Panel.qml`: `postPreampPeak`, `preampMax`, `peakSummary`, `autoPreamp`), and
every `withStatus()` reassigns the whole status object, so a single drag of a
band fader spends roughly 35–46 ms of JavaScript per pointer move. That is the
stutter reported in GitHub issue #3.

Identical results are available for 1.9 ms by building the coefficients once
(`Model.chainCoefficients`) and reusing `Model.responseSeries`.

## What to build

### 1. `Model.js` — same numbers, coefficients built once

- Add `peakFromCoefficients(coeffs, rate)` returning the same shape as
  `peakDb`: `{ db: <peak dB>, freq: <frequency of the peak> }`, measured on the
  **same sweep grid `peakDb` uses today** (20 → 20000 Hz, 401 points). Build the
  coefficients once for the sweep, evaluate every point from them.
- `peakDb(bands, preamp, rate)` keeps its exact signature and documented
  behaviour and now delegates to `peakFromCoefficients(chainCoefficients(bands,
  rate), rate)` with the preamp added on top (`responseSeries` already takes
  the preamp, so prefer passing it through and keeping the arithmetic in one
  place).
- The values must be **bit-identical** to today's, not merely close: the drawn
  curve, the backend's `awk` headroom port and `tests/headroom-check.js` all
  assume one peak definition. Add an assertion in the new test that
  `peakDb` and `peakFromCoefficients` agree to 1e-9 over: flat bands, a
  ten-band mixed curve, and a parametric set with shelves + a high-pass.
- Add `metrics(bands, sampleRate)` returning
  `{ peakDb, peakFreq, autoPreamp, signature }`:
  - `signature` = rate + a stable serialisation of every band's
    `type/freq/q/gain` (the order of bands is significant).
  - The whole object is memoised one-slot on `signature`: a second call with an
    equal signature returns the cached object without recomputing, even if the
    `bands` array is a different object with the same contents (the panel
    reassigns `status` constantly, so identity comparison is useless).
  - Export `resetMetricsCache()` for tests.
  - Keep `Model.js` otherwise stateless. No timers, no global state beyond that
    one slot.
- Add a coefficient-build counter that tests can read and reset, so "built
  once per metrics call" is asserted algorithmically instead of by wall clock:
  e.g. `Model.buildStats()` → `{ coefficientBuilds: n }` and
  `Model.resetBuildStats()`. Increment it inside `chainCoefficients` only (all
  the callers go through it).
- Keep the file's existing style: no semicolons (match the file), `var`,
  comments that explain *why*.

### 2. `Panel.qml` — read the memo once

Add one property and route the existing bindings through it:

```qml
readonly property var metrics: Model.metrics(bands, sampleRate)
```

- `postPreampPeak` → `metrics.peakDb + preamp`
- `peakSummary` → the same fields it reads today, from `metrics`
- `autoPreamp` → `metrics.autoPreamp`
- `preampMax` → unchanged arithmetic, reading `autoPreamp`
- `backendPreampCeiling` stays as it is (it comes from `status`, not the model).

Every displayed number must stay byte-identical: the peak text, the peak
frequency, the preamp ceiling, the headroom tooltip. `Model.formatFreq` is still
used for the readout.

### 3. Tests

New file `tests/metrics-check.js`, node only, same shape and tone as
`tests/preset-levels.js` (no framework: `PASS`/`FAIL` lines, a final
`N passed, M failed`, exit code 0/1). It must assert at least:

1. `peakDb` and `peakFromCoefficients` agree to 1e-9 on the three band sets.
2. `peakDb` still reports the peak frequency to within the sweep resolution.
3. `metrics()` calls `chainCoefficients` exactly once per cold computation
   (read the counter before and after).
4. A second `metrics()` call with a content-identical but different array
   returns the cached values and builds no coefficients.
5. Changing one band's gain, or the sample rate, invalidates the cache and
   rebuilds.
6. `metrics().peakDb`/`.autoPreamp` equal `Model.peakDb(...)`/`.autoPreampDb(...)`
   for the ten ISO bands.
7. Print the measured cold and warm timings for information (do not gate on
   them, machines differ): `console.log('      cold <x> ms  warm <y> ms')`.

Wire it into `tests/run-tests.sh` next to the other node checks (~line 216):

```sh
echo "== the panel's response metrics are computed once per band change =="
node "$here/metrics-check.js" >"$T/metrics-check.log" 2>&1; rc=$?
[[ $rc -eq 0 ]] || sed 's/^/      /' "$T/metrics-check.log"
check "the metrics memo is correct and builds coefficients once" "0" "$rc"
```

Follow the surrounding idiom exactly (`$here`, `$T`, `check`).

## Verification (must all pass before you report)

1. `node tests/metrics-check.js` → 0 failures.
2. `bash tests/run-tests.sh` → baseline is **248 passed, 0 failed**; yours must
   be `248 + <new assertions>` with 0 failed. Allow ~200 s; use a generous
   timeout (the suite also runs `qmltestrunner` offscreen).
3. `node tests/headroom-check.js` → unchanged pass, and
   `node tests/preset-levels.js` → still 109 passed.
4. `node tests/curve-check.js` → pass.

## Hard rules

- Never run the plugin's mutating commands (`enable`, `disable`, `set-*`,
  `apply-preset`, `import-autoeq`) or `pactl`/`systemctl` against the live
  session. The test suite uses stubs; that is the only sanctioned way to run
  the backend.
- Do not modify anything under `/usr/share/omarchy/**`.
- Do not edit `bin/omarchy-equalizer` in this phase — the panel-side fix must
  stand on its own.
- No git operations beyond read-only inspection.
- If a fact in this brief turns out to be wrong (line numbers drift, a function
  does not exist as described), trust the code, say so in your report, and do
  the equivalent correct thing rather than forcing the brief.

## Report back

- The exact functions/properties you changed, with the final `peakDb` code.
- The printed cold/warm timings from `metrics-check.js`.
- The new assertion count from `run-tests.sh`.
- Anything you could not verify, and anything that surprised you.
