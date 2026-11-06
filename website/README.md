# OFF42 website

The public, multilingual OFF42 product website for `https://off42.cc`, describing the native macOS and Windows apps.
It is independent of the native app build: only `website/dist/` is deployed.

## Build and preview

Requires Node.js 22 or later; no package installation or runtime dependencies.

```sh
cd website
npm run build
npm run check
npm run preview
```

Preview: `http://127.0.0.1:4242`. The root redirects to `/en/`; visitors can choose
one of 20 website languages, also available in the macOS interface. Each language has
13 fully rendered pages: home, feature index, eight features, downloads, open
source and privacy. Arabic uses RTL. Language links preserve the current route.

The generator fails on missing locale files. `--partial` is exclusively for local
translation work and must never be deployed; `npm run check` requires all 260
localized pages. Edit `locales/en.json` and every other locale together.

## Hosting

Cloudflare Workers Static Assets, Worker `off42`, account subdomain
`tr-zorin.workers.dev`. The dashboard's **Upload your static files** flow accepts
`dist/` with assets directory `/`, HTML handling `auto-trailing-slash` and not-found
handling `404-page`. Upload the directory contents; never upload the repository,
source, audit output or native app bundles.

Custom domains `off42.cc` and `www.off42.cc` are attached in the Worker's Domains tab. The canonical
site origin is `https://off42.cc`, including sitemap, alternate-language tags and
social previews. `/` redirects to `/en/`; `/404.html` is a noindex error page with error-specific metadata, without canonical or alternate-language links.
`_headers` sets content security and other response headers, including `no-transform` to prevent edge HTML injection. In the tested location this also resulted in uncompressed responses, a performance tradeoff. No analytics,
advertising, account system, cookies or file uploads are implemented by the site.
Cloudflare may process requests to serve and protect it.

Deployment metadata is recorded in `deployment.json`; detailed local audit evidence is in the root `STATUS.md`.
The Worker supports direct upload and Git-based deployment. For Cloudflare Workers Builds,
connect `sfzorin/off42` to the existing `off42` Worker with these settings:

| Setting | Value |
| --- | --- |
| Production branch | `main` |
| Root directory | `website` |
| Build command | `npm run build && npm run check` |
| Deploy command | `npx --yes wrangler@4.145.0 deploy` |
| Build watch paths | `website/**` |

`wrangler.jsonc` deploys only `dist/` and keeps the existing HTML and 404 handling.
For a manual update, build and check the site, package the contents of `dist/`, and upload
that archive to the existing Worker. Verify the canonical and `www` hosts, redirects and
representative routes after either deployment method.

## GitHub repository

The public repository is `https://github.com/sfzorin/off42`. The site reads
this address from `site.config.json` when building source, license, issues
and release links. Rebuild and redeploy after changing it.

## Installer links

No DMG or EXE release existed when the site was created. The project has separate macOS (Swift/Kit42) and Windows
(Rust) implementations. Downloads show the configured installer availability, GitHub releases and platform-specific
build instructions. This website does not build or distribute unverified native apps.

`site.config.json` has separate nullable `releases.macos` and `releases.windows`.
An enabled release entry must have:

```json
{
  "url": "https://github.com/OWNER/REPO/releases/download/TAG/OFF42-VERSION-arm64.dmg",
  "version": "VERSION",
  "architecture": "arm64",
  "requirements": "macOS 14+",
  "sha256": "64 lowercase hexadecimal characters"
}
```

After a verified installer is published, `npm run release:sync` looks for a stable
GitHub release asset named `OFF42-...dmg` or `Suite42-...dmg`. It requires an
unambiguous architecture and a GitHub SHA-256 digest. It updates configuration
only; it does not build, sign, notarize, publish or deploy anything. Verify the
actual app release using the repository's AGENTS.md rules before enabling it.
A new release on either platform also requires checking availability and requirements in all 20 locales.
No placeholder URL is offered as a real download.

## Verification

`npm run check` verifies the full locale schema, 260 unique page titles and
canonicals, 20-language alternates and x-default, local links and fragment targets,
assets, valid JSON-LD, sitemap, 404 noindex and configured release states.
Browser checks exercise menus, language switching, links and layout; see `QA.md`.
They do not verify native applications, certificate trust, OCR accuracy or Office
format fidelity. Translations have structural and editorial checks, not a review
by professional native speakers of all 20 languages.

## Search and sharing

Each page takes its `<title>` and meta description from the locale's `seo` block (home, features, downloads,
open source, privacy) or a feature's `seoTitle`/`seoDescription`. They use the phrases people search for
(“free PDF editor for Mac”, “compress PDF”) and differ from the visible headings, which keep the brand voice.
Titles carry the OFF42 name and must stay unique across all 260 pages. JSON-LD adds `SoftwareApplication`
(free offer, MIT license), with macOS and Windows in the general product metadata and macOS scope on feature pages.
It also adds `FAQPage` on the home and feature pages, plus `BreadcrumbList` on feature pages. The home page also lists the formats each app opens and saves and answers common questions;
the downloads page shows build-from-source commands with copy buttons while no installer is released.
Social previews use the 1200 × 630 `assets/og-image.jpg`. The sitemap omits `lastmod` until meaningful per-page dates are available. No `downloadUrl` is emitted while installer files are unavailable.
`/` redirects permanently (301) to `/en/`.

## Screenshots

`public/assets/shots/` holds real macOS screenshots of the six apps in all 20 languages (WebP, two widths each): the
interface runs in the page's language (`-Suite42Language`) and the documents are localized samples of fictional
companies — agreement and invoice, proposal letter, budget with chart, deck — with generated signatures and
country-style stamps (company stamps, round seals, hanko/kakuin, Chinese seals, “Paid” stamps). East Asian samples
seal instead of signing; Arabic samples are right-to-left. `screenshots/sizes.json` lists every image's size; the
build falls back to English for a missing language. Signature designs are pinned (`design` in the samples,
`K42_GENERATOR_DESIGNS` for the generator window) after contact-sheet review.

Optional regeneration requires a special external PDF42 binary supporting `--site-samples` at
`$OFF42_REPO/.build/debug/PDF42`, plus prebuilt isolated audit bundles. The current native
source tree does not include that helper; this pipeline is not self-contained. It also requires
`python-docx`, `openpyxl`, and `python-pptx`. Set `OFF42_REPO`, `OFF42_WEBSITE`, and
`OFF42_SAMPLES` when their default paths do not apply, then run
`website/screenshots/pipeline.sh en,ru` (or the required comma-separated languages).
The pipeline exits nonzero on failure. Rebuild and check the website after updating images.

## Assets

`public/assets/office-still-life.png` is the retained original generated hero;
`office-still-life.webp` is the optimized production image and `og-image.jpg` its 1200 × 630 social crop. The PNG is excluded
from `dist/`. `ARTWORK.md` records the creation prompt. Feature illustrations use
HTML/CSS/SVG, are identified as illustrations, and are not product screenshots.
