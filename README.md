# PDFSign

A dead-simple native macOS app for applying a **visible digital signature** to a PDF
using a certificate from your **Keychain** — the private key never leaves the Keychain.

No Adobe, no cloud, no accounts. Open a PDF, drag a box where the signature should go,
pick a certificate, sign. Or let an agent do the legwork (see [Agents & CLI](#agents--cli)).

## Features

- **Visible signature stamp** — your drawn/imported signature (or a seal icon) + signer name,
  UTC timestamp, and an optional text line.
- **Multiple fields** — place as many signature stamps, date fields (filled with the signing
  date, in a format you choose) and text fields as the document needs. Click a tool and drag
  (or just click for a default-sized field); select to move/resize, ⌫ to delete, ⌘D to
  duplicate, "Every Page" to repeat a field (e.g. initials) on all pages. One cryptographic
  signature covers all of them, and every signature stamp opens it in Acrobat's signature panel.
- **Existing signature fields** — if the document already has an empty signature field, it's
  highlighted ("Sign here"); click it and the signature goes into that field.
- **Rotated pages** — fields go where you see them and read upright on landscape/rotated pages.
- **Standards-based** — PAdES‑B (ETSI.CAdES, detached), SHA‑256. Output validates in
  Preview, Adobe Acrobat, and `pdfsig`.
- **Keychain-native** — signs with any identity in your Keychain, including non-exportable
  and Secure-Enclave keys. The raw signature is produced by `SecKeyCreateSignature`, so the
  private key is never exported.
- **Native UI** — SwiftUI (macOS 26), drag-to-place signature, the signed result stays on
  screen with a "Signed" badge.
- **Self-contained** — PoDoFo is statically linked; the app has no runtime dependencies
  beyond macOS itself.

## Agents & CLI

The app binary doubles as a headless CLI and an [MCP](https://modelcontextprotocol.io) server,
so an LLM agent can drive the whole flow: inspect the document, find where to sign, place
fields, render a preview to check them, confirm the certificate, sign and export.

```bash
PDFSign=/Applications/PDFSign.app/Contents/MacOS/PDFSign
$PDFSign help                                   # full reference
$PDFSign find contract.pdf "Signature"          # → page + rectangle of each match
$PDFSign render contract.pdf --page 3 --fields fields.json --out p3.png   # preview with grid
$PDFSign identities                             # certificates + SHA-256 fingerprints
$PDFSign sign contract.pdf --out signed.pdf --identity 4B90DF99 --fields fields.json
$PDFSign review contract.pdf --fields fields.json   # open in the app for you to sign
```

`fields.json` (PDF points on the page as displayed — rotation applied, as `render` shows it —
origin bottom-left, 1-based pages):

```json
{"fields": [
  {"type": "signature", "page": 3, "rect": {"x": 350, "y": 90, "width": 180, "height": 60}},
  {"type": "signature", "field": "ClientSignature"},
  {"type": "date",      "page": 3, "rect": [350, 60, 90, 18], "format": "yyyy-MM-dd"},
  {"type": "text",      "page": 3, "rect": [72, 60, 160, 18], "text": "Ljubljana"}
]}
```

A `"field"` entry fills one of the document's existing empty signature fields (names come from
`inspect`) instead of placing a box. All output is JSON. Certificates are chosen by exact fingerprint (or unique prefix) or exact
name — never fuzzily — and the input PDF is never modified. `review` hands the prepared
document to the GUI (fields placed, certificate pre-selected) so a human signs it.

**MCP:** register the server with your client, e.g. for Claude Code:

```bash
claude mcp add pdfsign -- /Applications/PDFSign.app/Contents/MacOS/PDFSign mcp
```

Tools: `list_identities`, `inspect_pdf`, `get_text`, `find_text`, `render_page` (returns the
PNG), `sign_pdf`, `open_for_review`.

To get a `pdfsign` command, use a wrapper script rather than a symlink — the binary locates
its bundle from its real path:

```bash
printf '#!/bin/sh\nexec /Applications/PDFSign.app/Contents/MacOS/PDFSign "$@"\n' > /usr/local/bin/pdfsign
chmod +x /usr/local/bin/pdfsign
```

## How it works

The interface and cryptography are pure Apple frameworks (SwiftUI, PDFKit, Security). The
PDF signature *container* — the CMS/PKCS#7 blob, the `/ByteRange`, and the incremental
update — is built by [PoDoFo](https://github.com/podofo/podofo). PoDoFo is given only the
X.509 certificate and delegates the actual signing to a callback wired to
`SecKeyCreateSignature`, so the private key stays in the Keychain the whole time.

A thin Objective‑C++ layer (`PDFSign/SigningEngine`) bridges Swift to PoDoFo; its public
header is C++-free so Swift imports it via a bridging header.

## Build

Requires Xcode 26+ and [Homebrew](https://brew.sh).

```bash
brew install xcodegen cmake
./scripts/build-podofo.sh     # one-time: builds a static PoDoFo into vendor/ (git-ignored)
xcodegen generate
open PDFSign.xcodeproj         # or: xcodebuild -scheme PDFSign -configuration Debug build
```

`scripts/build-podofo.sh` builds PoDoFo with `PODOFO_BUILD_STATIC` and merges it with its
static dependencies into a single archive (`vendor/podofo/lib/libpodofo_bundle.a`) that the
app links. The resulting `.app` has **zero `/opt/homebrew` runtime dependency**.

## Status

Personal tool, early days. Out of scope for now: RFC 3161 trusted timestamps, PAdES LTV,
and multiple *cryptographic* signatures in one pass (re-signing a signed output does work —
each pass is a new incremental revision).

Release builds are signed with a **Developer ID Application** certificate, built with the
**Hardened Runtime** and a secure timestamp, and **notarized** by Apple (then stapled), so
they pass Gatekeeper without warnings. The dev (Debug) build stays ad-hoc signed for a fast
local loop. To produce a notarized build:

```bash
./scripts/notarize.sh    # Release build → notarize (via asc) → staple → verify; output in dist/
```

Notarization uses [`asc`](https://github.com/aaronsky/asc) (App Store Connect API key);
see `AGENTS.md` for details.

## License

PDFSign's own code is licensed under the
**[PolyForm Noncommercial License 1.0.0](LICENSE.md)** — free to use, modify, and share
for **noncommercial** purposes, provided you keep the required attribution
(© Jernej Štrasner, with a link back to this repository). It is source-available, not OSI
open source. For commercial use, get in touch.

### Third-party

PDFSign is built on **[PoDoFo](https://github.com/podofo/podofo)**, a C++ PDF manipulation
library dual-licensed **`LGPL-2.0-or-later` OR `MPL-2.0`**; PDFSign statically links it
under the **MPL-2.0** option. PoDoFo in turn depends on OpenSSL, FreeType, Fontconfig,
libpng, libtiff, libjpeg-turbo and others — see PoDoFo's
[NOTICE](https://github.com/podofo/podofo/blob/master/NOTICE) for their licenses. These
third-party components keep their own licenses; PDFSign's license covers only its own code.
