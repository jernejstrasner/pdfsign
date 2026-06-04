# PDFSign

A dead-simple native macOS app for applying a **visible digital signature** to a PDF
using a certificate from your **Keychain** — the private key never leaves the Keychain.

No Adobe, no cloud, no accounts. Open a PDF, drag a box where the signature should go,
pick a certificate, sign.

## Features

- **Visible signature stamp** — seal icon + signer name, UTC timestamp, and optional reason.
- **Standards-based** — PAdES‑B (ETSI.CAdES, detached), SHA‑256. Output validates in
  Preview, Adobe Acrobat, and `pdfsig`.
- **Keychain-native** — signs with any identity in your Keychain, including non-exportable
  and Secure-Enclave keys. The raw signature is produced by `SecKeyCreateSignature`, so the
  private key is never exported.
- **Native UI** — SwiftUI (macOS 26), drag-to-place signature, the signed result stays on
  screen with a "Signed" badge.
- **Self-contained** — PoDoFo is statically linked; the app has no runtime dependencies
  beyond macOS itself.

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
and multiple signatures.

Release builds are signed with a **Developer ID Application** certificate, built with the
**Hardened Runtime** and a secure timestamp, and **notarized** by Apple (then stapled), so
they pass Gatekeeper without warnings. The dev (Debug) build stays ad-hoc signed for a fast
local loop. To produce a notarized build:

```bash
./scripts/notarize.sh    # Release build → notarize (via asc) → staple → verify; output in dist/
```

Notarization uses [`asc`](https://github.com/aaronsky/asc) (App Store Connect API key);
see `CLAUDE.md` for details.

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
