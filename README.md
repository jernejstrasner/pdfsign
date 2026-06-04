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
and multiple signatures. The distribution build (App Sandbox, Developer ID signing,
notarization) is still TODO — the dev build is ad-hoc signed.

## Third-party & licensing

PDFSign is built on **[PoDoFo](https://github.com/podofo/podofo)**, a C++ PDF manipulation
library, which is dual-licensed **`LGPL-2.0-or-later` OR `MPL-2.0`**. PDFSign statically
links PoDoFo under the **MPL-2.0** option. PoDoFo itself depends on OpenSSL, FreeType,
Fontconfig, libpng, libtiff, libjpeg-turbo and others — see PoDoFo's
[NOTICE](https://github.com/podofo/podofo/blob/master/NOTICE) for their respective licenses.

A license for PDFSign's own code has not been chosen yet.
