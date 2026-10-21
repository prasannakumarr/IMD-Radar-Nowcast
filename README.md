# Real Time Weather

A live rain-radar nowcast for Tamil Nadu, decoded from the public radar
imagery that IMD publishes at `mausam.imd.gov.in`.

Run it, a browser opens, you see where the rain is. Refresh and you get
whatever the server currently holds.

```bash
cabal run realtime-weather
```

[![CI](https://github.com/prasannakumarr/IMD-Radar-Nowcast/actions/workflows/ci.yml/badge.svg)](https://github.com/prasannakumarr/IMD-Radar-Nowcast/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Haskell GHC 9.10](https://img.shields.io/badge/GHC-9.10-5e5086.svg)](https://www.haskell.org/ghc/)

![Scattered showers tracking up the Palar basin towards Kalpakkam. Soft
green-to-amber echo over Tirukalukundram, with the reflectivity scale in the
corner.](docs/images/radar-palar-showers.webp)

<sub>A quiet evening: light showers over the Palar basin, 20–35 dBZ. Most of
this echo is only visible because the X-band radar is in the fusion.</sub>

---

## What it does

IMD publishes radar as a **picture**, not data. This reads the picture back
into numbers — dBZ per pixel — fuses three radars into one view, finds storm
cells, and serves the result as a map you can leave open in a tab.

* **Three radars, one picture.** Chennai S-band, Karaikal S-band, and the
  Pallikaranai X-band, fused so the finest instrument wins where they overlap.
* **No API key required.** The basemap falls back to a keyless Esri layer, so
  a fresh clone works with no credentials at all.
* **Instant.** The page never waits on IMD. Sub-millisecond responses, served
  from memory.
* **Honest about coverage.** Scan boundaries are drawn, so "no echo" never
  gets confused with "outside this radar's range".

![A heavy convective line over Pulicat Lake and Sri City, with 40–50 dBZ cores
picked out in orange and red against the lagoon.](docs/images/radar-pulicat-squall.webp)

<sub>The same map during an active event: a convective line over Pulicat Lake,
cores at 40–50 dBZ.</sub>

## Quick start

Needs GHC 9.10 and Cabal 3.12+ (easiest via [ghcup](https://www.haskell.org/ghcup/)).

```bash
git clone https://github.com/prasannakumarr/IMD-Radar-Nowcast.git
cd IMD-Radar-Nowcast
cabal run realtime-weather
```

That is the whole setup. A browser opens at `http://localhost:8080`, the map
paints immediately, and the first radar scan lands a couple of seconds later.

To use a nicer basemap or to pin your own locations, copy the config template:

```bash
cp .env.example .env     # then fill it in
```

## The shape of it

The thing worth understanding before reading any code:

```
    IMD GIF  ──►  pure decode  ──►  Snapshot  ──►  TVar  ──►  HTTP handlers
                                                     ▲
                        background loop owns freshness
```

**A background loop owns freshness and publishes whole immutable `Snapshot`s
into a `TVar`. HTTP handlers only ever read that TVar.**

Everything good follows from that one decision:

* a request never waits on IMD, so first paint is instant;
* a request never fails because IMD failed — you see the last good scan;
* layers and cells are always mutually consistent, because they are swapped
  together as one value;
* "refresh for an update" works without any coordination, because a refresh is
  just another read.

The alternative — fetching on the request path with a cache in front — races
the user against a government web server. This doesn't race; it decouples.

## Functional core, imperative shell

| Module | Purity | Job |
|---|---|---|
| `RTW.Config` | data + a little IO | Per-radar calibration; settings from the environment |
| `RTW.Decode` | **pure** | GIF → dBZ grid → PNG overlay; the geo transform |
| `RTW.Cells` | **pure** | Grid → storm cells; multi-radar fusion |
| `RTW.Page` | **pure** | The page shell, embedded at compile time |
| `app/Main` | IO | Fetch, cache, serve, open the browser |

`RTW.Decode` is the heart and it is one composition over immutable values:

```haskell
decode p img = despeckle (classify (buildLut p img) (dedither (crop (pPanel p) img)))
```

Nothing in there can fail at a distance, and all of it is testable without a
network, a server, or a clock.

## How the decode works

The picture is self-describing, because Rainbow (the SELEX software that
renders it) prints its own colour bar with the dBZ values labelled at each end.

1. **Build the ruler.** Sample the colour bar row by row → a colour → dBZ
   lookup table. Nothing is hardcoded; change the palette upstream and this
   follows.
2. **De-dither.** 2×2 box mean. This is the step that earns its keep: on the
   Chennai skin the Bay of Bengal is itself a dither pair whose two colours
   also belong to the 32.5 and 35 dBZ echo dithers. Per-pixel matching cannot
   tell sea from drizzle and floods the ocean with phantom rain.
3. **Match.** Nearest colour on the ruler by distance in RGB space; further
   than the tolerance and it isn't echo at all, it's coastline or terrain.
4. **Despeckle.** Drop isolated pixels, and keep near-white only next to other
   echo — white is both ~37.5 dBZ and the colour of the printed map labels.
5. **Place it.** One anchor (the dish's pixel and its real lat/lon) plus one
   scale (km per pixel), then flat-earth arithmetic at 111 km/degree. That is
   the same approximation Rainbow used to draw the picture.

The per-site layout is the one thing that *isn't* self-describing — each IMD
site uses a different Rainbow skin. Those few numbers live in `products` in
`RTW.Config`, measured once.

**[→ The Annexure](ANNEXURE.md)** covers the rest: which radars are in and
which were rejected and why, how the geo transform was verified to ~200 m, the
two resolution traps that mixing S-band and X-band created, and the TLS
handshake gotcha that makes `mausam.imd.gov.in` look unreachable.

## Performance

Measured, not estimated:

| | |
|---|---|
| `GET /` (page shell) | **~0.5 ms** |
| `GET /api/state` (warm) | **~0.8 ms** |
| First radar data after startup | **~2 s**, in the background |
| Steady state | served from memory; IMD is touched every `REFRESH_SECONDS` |

The page paints immediately and shows a spinner only until the first snapshot
lands. After that, refreshes are instant — you are reading RAM, not the
internet.

## Configuration

Settings come from the environment. `.env` fills gaps but **real environment
variables always win**, because `.env` is a developer convenience and should
never shadow production config.

| Variable | Default | Meaning |
|---|---|---|
| `MAPBOX_TOKEN` | *(unset)* | Mapbox **public** token (`pk.*`) |
| `MAPBOX_STYLE` | *(unset)* | `username/styleid` of a published **classic** style |
| `CARTO_KEY` | *(unset)* | CARTO basemap key |
| `PORT` | 8080 | Local server port |
| `REFRESH_SECONDS` | 600 | How often to re-fetch from IMD |
| `PLACES` | Chennai landmarks | Map pins as `Name:lat:lon,…`; the first is the map centre |

The basemap is chosen purely from configuration, first fully-configured wins:
**Mapbox → CARTO → keyless Esri**, so the map still works with no credentials
at all.

Two Mapbox-specific traps, both already handled in `RTW.Page`:

* It must be a **classic** style. The modern Mapbox Standard style is
  vector-only and cannot be served as raster tiles to Leaflet.
* Mapbox serves **512 px** tiles and Leaflet assumes 256, so the tile layer
  needs `tileSize: 512, zoomOffset: -1`. Omit them and every label renders at
  double size with zoom levels silently off by one — it looks like a styling
  mistake rather than a bug.

Style edits need no code change: recolour in Studio, hit Publish, and the
running app picks it up (the Production URL is cached for a few minutes).

### `PLACES` and why it is configuration

The pins are config, not source, so that nobody has to commit the place they
actually live in order to use this. The committed defaults are city-scale
landmarks rounded to three decimals (~100 m); your own neighbourhood belongs
in your `.env`:

```bash
PLACES=Besant Nagar:13.000:80.267,Tambaram:12.926:80.118
```

Six decimals is roughly a doorstep. Three is plenty for a radar map whose
finest pixel is 95 m across.

## Security and secrets

`.env` is gitignored; `.env.example` is committed and documents the shape.
Both basemap credentials are *public* keys that ship inside client HTML, so
they are not really secrets — but they **are** rate-limited and billable, so
restrict them by URL or domain in the provider dashboard before publishing.
Never put a Mapbox `sk.*` secret token here.

See **[SECURITY.md](SECURITY.md)** for the full threat model, including the
one thing worth knowing before you run this on a shared network: the server
binds all interfaces, not just loopback.

## Data, attribution and disclaimer

Radar imagery is sourced from the **India Meteorological Department**
(`mausam.imd.gov.in`), a Government of India public service. This project
decodes publicly published imagery; it is **not affiliated with, endorsed by,
or supported by IMD**, and it redistributes no IMD imagery — every scan is
fetched at runtime by the person running the software.

The default refresh interval is 600 s because the radars only produce a new
scan every 10–25 minutes. **Please do not lower it.** Anything faster is
wasted load on a public weather service and gains you nothing.

Basemap tiles are © Mapbox, © OpenStreetMap contributors, © CARTO, or Esri,
depending on which is configured; each is attributed in the map corner.

> **This is not an official forecast.** It is a hobby decoder of radar
> pictures, with known limitations documented in the
> [Annexure](ANNEXURE.md) — notably X-band attenuation behind heavy cores.
> For warnings and official nowcasts, use
> [mausam.imd.gov.in](https://mausam.imd.gov.in/).

## Layout

```
app/Main.hs          fetch, cache, serve
src/RTW/Config.hs    calibration + settings
src/RTW/Decode.hs    the pure decoder
src/RTW/Cells.hs     storm cells
src/RTW/Page.hs      page shell
static/index.html    the actual HTML, embedded at compile time
docs/images/         screenshots used in this README
ANNEXURE.md          the long-form engineering notes
```

## Contributing

Issues and pull requests are welcome. Keep `cabal build` warning-free (CI
runs with `-Werror`), `fourmolu --mode check` and `hlint src app` clean, and
the pure modules pure. The most useful contributions right now are
calibration data for IMD sites outside Tamil Nadu — see
[Not here yet](ANNEXURE.md#not-here-yet) for how to measure a new site — and
a test suite for the decoder.

## License

[MIT](LICENSE). IMD imagery is public government data and is not covered by
this licence.
