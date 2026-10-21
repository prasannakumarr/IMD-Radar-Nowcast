## What this changes

<!-- One or two sentences. One concern per PR, please. -->

## Why

<!-- The trap you hit, the measurement that motivated it, the bug it fixes. -->

## How it was verified

<!-- This codebase is full of numbers that came from measurement. If you
     changed a calibration constant, a threshold, or the geo transform, say
     what you checked it against and how closely it agreed. -->

## Checklist

- [ ] `cabal build` is warning-free (CI runs with `-Werror`)
- [ ] `fourmolu --mode check $(git ls-files '*.hs')` is clean
- [ ] `hlint src app` is clean
- [ ] The pure modules (`RTW.Decode`, `RTW.Cells`, `RTW.Page`) are still pure
- [ ] No secrets, personal coordinates, or absolute local paths in the diff
