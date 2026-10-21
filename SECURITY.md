# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Use GitHub's private vulnerability reporting: go to the **Security** tab →
**Report a vulnerability**. That opens a private thread visible only to the
maintainers.

Expect an acknowledgement within a few days. This is a hobby project
maintained in spare time, so please be patient with fix timelines.

## Threat model

This is a **local, single-user tool** that fetches public government imagery
and serves a read-only map. It stores no user data, has no database, no
accounts, no authentication, and no write endpoints. The realistic risks are
small, but they are worth stating plainly.

### The server binds all interfaces

`scotty` listens on `0.0.0.0`, not just loopback. Anyone on the same network
can reach `http://<your-ip>:8080` and see the map.

This is deliberate — being able to open the radar on a phone over Wi-Fi is
most of the point of a weather map. But know what it means:

* **Do not run it on untrusted networks** (cafés, conference Wi-Fi, hotels).
* Your configured `PLACES` pins are served to anyone who can reach the port.
  If you have put your actual address in there, that is now visible on the
  LAN.
* Your basemap key is embedded in the served HTML and is therefore readable
  by anyone who loads the page. See below.

If you want loopback-only, run it behind a firewall rule or bind the port
with your platform's tooling. There is currently no `HOST` setting.

### Basemap keys are public by design

`MAPBOX_TOKEN` and `CARTO_KEY` are injected into the page HTML and shipped to
the browser. That is how these providers work — they are **publishable**
keys, not secrets.

What matters is that they are restricted and cheap to lose:

* **Mapbox** — use a `pk.*` public token. **Never** an `sk.*` secret token;
  those grant account-level API access. Restrict the token by URL in the
  Mapbox dashboard before you publish anything.
* **CARTO** — restrict by domain. The key is rate-limited and billable even
  though it is not confidential.
* Both are read from the environment at runtime. Neither is ever written to
  a file by this program, logged, or returned by `/api/state`.

If you accidentally commit one, rotate it in the provider dashboard. Removing
the commit is not sufficient — assume anything pushed to a public repository
is permanently disclosed.

### Outbound TLS

`imdManager` in `app/Main.hs` relaxes exactly one TLS requirement: it allows
peers that do not support RFC 7627 Extended Main Secret, because
`mausam.imd.gov.in` does not. Certificate validation and hostname
verification both remain **on**, and the relaxed `Manager` is used only for
IMD requests — it cannot leak into other connections. See the
[Annexure](ANNEXURE.md#the-tls-gotcha) for the full story.

### Third-party client assets

The page loads Leaflet 1.9.4 from `unpkg.com`, pinned with Subresource
Integrity (`sha384-…`) and `crossorigin="anonymous"`. If the CDN ever serves
different bytes, the browser refuses the file rather than executing it. When
bumping the Leaflet version, **recompute the hashes**:

```bash
curl -sL https://unpkg.com/leaflet@X.Y.Z/dist/leaflet.js \
  | openssl dgst -sha384 -binary | openssl base64 -A
```

### Input handling

* `/layer/:code` resolves the path parameter against a fixed whitelist of
  known product codes. Unknown codes return 404; no path is constructed from
  user input, so there is no traversal surface.
* `PLACES` comes from the operator's own environment, and is serialised into
  the page with `aeson` rather than string concatenation, so a quote or angle
  bracket in a place name cannot break out into script context.
* Nothing from IMD's response is interpolated into HTML. Images are decoded
  by `JuicyPixels` into a pixel grid and re-encoded as PNG.

### Dependency supply chain

Haskell dependencies come from Hackage and are resolved by Cabal. GitHub
Actions are pinned to full commit SHAs and updated by Dependabot. There is no
`npm` dependency tree.

## Scope

Out of scope: denial of service against your own local instance, and the
inherent exposure of running an unauthenticated service on your LAN (see
above — it is documented, not a vulnerability).
