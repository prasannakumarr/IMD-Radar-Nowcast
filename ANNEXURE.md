# Annexure — engineering notes

Long-form notes that would crowd the [README](README.md): which radars are in
and which were deliberately left out, how the geo transform was verified, the
traps that mixing resolutions created, and the one protocol-level gotcha that
makes IMD look unreachable.

Most of this exists so that decisions already made do not get re-litigated.

**Contents**

1. [Radars in use](#radars-in-use)
2. [Why the X-band radar earns its place](#why-the-x-band-radar-earns-its-place)
3. [The attenuation caveat](#the-attenuation-caveat)
4. [Two traps that mixing resolutions created](#two-traps-that-mixing-resolutions-created)
5. [How the geo transform was verified](#how-the-geo-transform-was-verified)
6. [Considered and rejected: Sriharikota](#considered-and-rejected-sriharikota)
7. [The TLS gotcha](#the-tls-gotcha)
8. [Not here yet](#not-here-yet)
9. [Going public: privacy, secrets and repository decisions](#going-public-privacy-secrets-and-repository-decisions)

---

## Radars in use

| | Band | Range | km/px | Distance to southern Chennai |
|---|---|---|---|---|
| Chennai DWR (`caz_cni`) | S | 250 km | 1.0 | 27 km |
| Karaikal DWR (`caz_kkl`) | S | 250 km | 0.96 | 217 km |
| Chennai X-DWR, Pallikaranai (`caz_plk`) | **X** | 85 km | **0.095** | **11 km** |

Layers are ordered coarsest-first, so the fine X-band picture draws on top of
the wide S-band ones where they overlap.

## Why the X-band radar earns its place

It is not a third opinion on the same thing — it is a different instrument.
Shorter wavelength means far higher sensitivity to light rain, and ~10× the
spatial resolution, sited 11 km from the area the map is about. Measured on a
quiet night, over sky both radars can see:

```
                        20-25 dBZ echo    within 10 km of dish
X-DWR   (X-band)              74%                 2.2%
Chennai (S-band)              39%                 0%
```

The extra echo is overwhelmingly light rain, and it is *not* piled up near the
dish where ground clutter would be. That is the sensitivity advantage showing
up, not noise.

## The attenuation caveat

X-band attenuates severely in heavy rain, so reflectivity *behind* an intense
core is underestimated or missing entirely. This is physics, not a bug, and
anyone reading the map during a severe event needs to know it.

It also means `fuse` keeping the **strongest** report is the correct rule for
this pair, which is a happy accident:

* light rain — X sees it, S misses it, max picks X ✓
* heavy rain — X attenuates and under-reports, S barely attenuates, max picks S ✓

Note this reasoning does **not** generalise. Two co-located *S-band* radars
disagreeing is just calibration noise, and "strongest wins" would turn that
into a systematic high bias — see [Sriharikota](#considered-and-rejected-sriharikota).

## Two traps that mixing resolutions created

Both are the same mistake in different places: a **pixel** criterion where an
**area** criterion was meant. Neither radar alone would have revealed either.

### 1. Cell detection

`findCells` originally required a blob of 4 pixels. At 1 km/px that is a
4 km² shower; at 0.095 km/px the same four pixels is 0.036 km² — a speck.
Adding the X-band radar immediately produced phantom cells like
*"46 dBZ, 0.1 km²"*. Fixed with `minCellKm2 = 4.0` in `RTW.Cells`, which
preserves the old S-band behaviour exactly.

### 2. The painted overlay

`despeckle` keeps a pixel if 3 of its 8 neighbours are also echo. At 1 km/px,
surviving that means being a few km². At 0.095 km/px a 2×2 patch of 0.036 km²
sails through. The result:

```
                      blobs drawn    under 0.25 km2
X-DWR, before              372             277
X-DWR, after                18               0
```

**277 of 372 blobs were specks** — visually dominant while making up only 11%
of the echo area. At night, from a coastal X-band radar, sub-km² returns at
20 dBZ are most likely nocturnal insects, sea clutter, or noise at the
detection threshold. Not rain.

Fixed with `minEchoKm2 = 1.0` in `prune` (`RTW.Decode`) — one square kilometre
is exactly one pixel of the S-band radars, so the rule reads *"do not paint
anything the coarser radars could not even resolve"*. It is a no-op at
1 km/px, so S-band output is untouched.

## How the geo transform was verified

Three independent checks, because a misregistered radar overlay is worse than
no overlay:

1. **Range rings.** Measured at 211 / 422 / 633 px for the 20 / 40 / 60 km
   rings — exactly linear, giving `20/211 = 0.09479 km/px`.
2. **Centre cross.** The radial grid's centre lands on panel-local
   (899.5, 899.5), the exact centre of the 1800×1800 panel.
3. **An independent implementation.** The computed bounds agree with
   plots.chennairains.com's hardcoded bounds for the same product to within
   **~200 m on a 170 km panel**.

## Considered and rejected: Sriharikota

IMD also publishes a radar at Sriharikota — `caz_shr.gif`, animation
`SHR_MAXZ.gif`. It was evaluated and deliberately left out. Recording why, so
it doesn't get re-litigated.

**It is not a feasibility problem.** The projection checks out: what look like
curved graticule lines are range rings, and the real graticule is straight and
axis-aligned, same plate carrée as the others. The panel is exactly 1800×1800
px with a printed range of 240 km, so the scale falls out without measuring
anything: `480 km / 1800 px = 0.2667 km/px`. It is roughly 20 minutes of
calibration work.

**The geometry is the problem.**

```
SHAR to Chennai DWR        65 km apart   <- nearly co-located
SHAR reaches north to      15.83 N
Chennai reaches north to   15.34 N
genuinely new coverage     54 km crescent
southern Chennai to Chennai DWR   27 km  <- already the better instrument here
southern Chennai to SHAR          91 km
```

**The lead-time argument does not survive scrutiny.** 54 km of extra northern
reach looks like 82–165 minutes of earlier detection, but anything approaching
Chennai from the north is already seen the moment it enters Chennai DWR's
250 km ring — about 8 hours out at 30 km/h. SHAR extends that to ~9.8 hours.
Nobody needs the tenth hour. And during the NE monsoon, Chennai's rain
predominantly arrives from the east/northeast across the Bay, which Chennai
DWR already covers; SHAR's crescent is off the dominant approach vector.

**It would add noise, not just cost.** `fuse` keeps the *strongest* report
where radars overlap. Two nearly co-located radars with different calibration,
beam geometry and scan times disagree slightly on the same storm, and
"strongest wins" turns that disagreement into a systematic high bias in
reported dBZ. A third almost-entirely-overlapping radar makes that worse
precisely in the area that matters most — in exchange for **6.2× the decode
work** (3,240,000 px vs 520,420) and **4.4× the download** (1.2 MB vs 0.27 MB).

**What would change the decision**

* Caring about Nellore / Ongole (15–15.8 N). Then SHAR is the right radar and
  Chennai is the marginal one.
* Wanting to *replace* Chennai DWR near the coast rather than fuse with it —
  SHAR is 3.7× finer (0.267 vs 1.0 km/px). That means switching `fuse` from
  "strongest wins" to "best-placed radar per pixel", which is a more careful
  piece of work than adding a third layer.

## The TLS gotcha

`mausam.imd.gov.in` predates RFC 7627, and `tls >= 2` **requires** Extended
Main Secret by default, so the handshake is refused outright with
`peer does not support Extended Main Secret`. Browsers and curl are lenient
about it, which makes this look like a code bug rather than a protocol one.

`imdManager` in `app/Main.hs` relaxes exactly that requirement and nothing
else — certificate validation stays on, hostname verification stays on. The
relaxation is scoped to the one `Manager` used for IMD, so it cannot leak into
any other connection the process makes.

If you ever see that error again after a dependency bump, this is the place to
look.

## Not here yet

**Motion arrows.** Direction and speed need the 3-hour animation GIFs, which
are 2–8 MB per radar and would make the refresh loop far heavier. The honest
fix isn't to download them on a timer, it's to keep a local archive of the
small still images and diff successive scans — which also gives exact
timestamps, something the animation GIF never provides.

**A test suite.** The decoder is pure and takes a `DynamicImage` to a `Grid`,
so it is unusually easy to test: a handful of checked-in reference GIFs and
their expected cell lists would lock in the calibration constants and catch an
upstream palette change immediately. This is the single most valuable thing a
contributor could add.

**More IMD sites.** `products` in `RTW.Config` is plain data, so adding a
site is measurement rather than programming. Each site uses a different
Rainbow skin, so the layout has to be measured once from an actual image:

1. Download the still, e.g. `https://mausam.imd.gov.in/Radar/caz_xxx.gif`.
2. Open it in any image editor with a pixel readout and record:
   * `pBar` — the rectangle of the printed reflectivity colour bar, and the
     dBZ values at its two ends (`pDbzLo`, `pDbzHi`).
   * `pPanel` — the rectangle of the radar panel itself, excluding the
     surrounding chrome.
   * `pSiteX` / `pSiteY` — the dish pixel in **full-image** coordinates. The
     centre cross of the radial grid is the reliable landmark.
   * `pKmPerPx` — measure two or three range rings and check the relationship
     is linear before trusting it. Write it as the division that produced it
     (`20 / 211`), not the decimal, so the measurement stays visible.
   * `pLat` / `pLon` — the real location of the dish.
3. Add the `Product`, ordered **coarsest-first** in the list: later layers
   draw on top, so finer radars must come later.
4. Verify against a known event before trusting it. A misregistered overlay
   is worse than no overlay.

Read [Considered and rejected: Sriharikota](#considered-and-rejected-sriharikota)
first. A new radar that mostly overlaps an existing one makes the fused
output *worse*, because `fuse` keeps the strongest report and co-located
radars disagree. More coverage is good; more overlap usually isn't.

---

## Going public: privacy, secrets and repository decisions

A record of what was checked and what was decided when this went from a
folder on a laptop to a public repository. Kept so the same ground does not
get re-covered, and so the privacy decisions are not quietly undone later.

### What was audited before the first commit

This was never a git repository before publication, so there is no history to
scrub and **no credential was ever committed**. That was verified rather than
assumed, against the actual staged blobs rather than the working tree:

| Check | Method | Result |
|---|---|---|
| Live credential leakage | Every value in `.env` searched for, byte-for-byte, in all 28 staged blobs | 0 hits |
| Credential *shapes* | Pattern scan for `pk.*` / `sk.*` / `cb1_*`, AWS `AKIA`, GitHub `ghp_`, Google `AIza`, JWTs, PEM private keys | none |
| Personal identifiers | Scan for local paths (`/Users/`, `/home/`), personal email, home locality | none |
| Image metadata | RIFF chunk walk over both screenshots | single `VP8L` chunk each; no EXIF, no GPS |
| Exclusions | `git check-ignore` on `.env`, `dist-newstyle/`, `.DS_Store` | all excluded |

Two `.DS_Store` files were deleted and are now gitignored.

Re-run the credential checks before any future push that touches
configuration. `git ls-files` plus `git grep --cached` is the right tool —
scanning the working tree tells you nothing about what git will actually
send.

### The one real privacy problem, and why it was fixed this way

`static/index.html` used to hardcode:

```js
const PLACES = [['<home suburb>', 12.84###, 80.22###], ...];
```

That was both the first map pin and the default map centre, with the
coordinate given to five decimal places — roughly one metre. Combined with a
README that measured every radar distance to that same suburb by name, the
repository would have published a home address to anyone who read it.

(The real values are deliberately not reproduced here. A document explaining
why a coordinate was removed is a silly place to put the coordinate back.)

It was **not** fixed by rounding the number in place, because that leaves the
next person to add their own street back in. The pins became configuration:

* `PLACES` is parsed in `RTW.Config` from `Name:lat:lon,Name:lat:lon`.
* Entries that do not parse are skipped, and an entirely unparseable value
  falls back to the defaults — a typo in config should not produce a blank
  map.
* Committed defaults are city-scale Chennai landmarks rounded to three
  decimals (~100 m). The finest radar pixel is 95 m across, so three decimals
  is already past the point of meaning.
* The page receives the list through `aeson`, not string concatenation, so a
  quote or angle bracket in a place name cannot escape into script context.

Prose in the README and `RTW.Config` now says "southern Chennai" rather than
naming a specific neighbourhood.

**The coordinates that remain above three decimals are radar dish positions.**
Those are public infrastructure and the geo transform needs their precision —
they are not an oversight, and they should not be rounded.

### Basemap keys are public, but not free

`MAPBOX_TOKEN` and `CARTO_KEY` are injected into the page and shipped to the
browser. They are publishable keys by design, so secrecy is not the control —
**restriction is**. Restrict by URL (Mapbox) and by domain (CARTO) in the
provider dashboard. Never use a Mapbox `sk.*` secret token; those carry
account-level API access.

### Judgement calls worth not reversing by accident

**The server binds `0.0.0.0`, deliberately.** Opening the radar on a phone
over home Wi-Fi is most of the point of a weather map, so this was documented
in [SECURITY.md](SECURITY.md) rather than "fixed". The cost is real though:
anyone on the same network can read your configured `PLACES`. Do not run this
on café or conference Wi-Fi. If loopback-only is ever wanted, it needs a
`HOST` setting and `scottyOpts`, not a quiet default change.

**No dependency upper bounds.** `cabal check` will keep suggesting them.
Upper bounds are PVP guidance for libraries published to Hackage; this is an
application, and bounds here buy maintenance burden rather than safety. CI
pins GHC 9.10.1 instead. If reproducibility ever becomes a real problem, the
right tool is `cabal.project.freeze`, not hand-written bounds.

**Leaflet is pinned by Subresource Integrity.** The `sha384` hashes were
computed from the bytes unpkg actually serves, not copied from a tutorial.
They must be recomputed on every Leaflet version bump or the page silently
stops loading its map library — the command is in
[SECURITY.md](SECURITY.md#third-party-client-assets).

**`static/index.html` is in `extra-source-files`.** `RTW.Page` embeds it at
compile time via `file-embed`, so an sdist that omits it fails to build. This
is easy to break and hard to notice locally.

### Tooling choices

`-threaded -rtsopts -with-rtsopts=-N` were moved out of the shared `common`
stanza into an executable-only one; `cabal check` correctly flagged that they
were silently inert on the library.

`hlint` and `fourmolu` were installed and run against the real tree before
being added to CI, rather than being wired up and hoped for. Making them pass
cost a one-time 110-line formatting pass, most of it `import X qualified`
moving to the postfix form, which GHC2021 makes unavoidable under fourmolu.

Both configs encode the project's actual standards rather than tool defaults:
`fourmolu.yaml` matches the two-space, leading-comma, `-- |` style already in
the tree, and every `.hlint.yaml` exception states why. The partial-function
ban in `.hlint.yaml` scopes its `!!` exemption to `RTW.Decode.dilate`, which
indexes `iterate step v0` — an infinite list, so the index cannot run off the
end.

### Still outstanding

* **A test suite.** See [Not here yet](#not-here-yet). CI currently proves
  only that the project builds warning-free and lints clean.
* The CI badge in the README 404s until the first push reaches GitHub.
