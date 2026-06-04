# PDFSign

A dead-simple native macOS app that applies a **visible digital signature** to a PDF
using a certificate from your **Keychain** — the private key never leaves the Keychain.

- **UI:** SwiftUI (macOS 26 / Tahoe), `@Observable` state, three-state flow
  (open → place box → sign & save).
- **Crypto:** Apple Security.framework. The identity is read from the Keychain and the
  raw signature is produced by `SecKeyCreateSignature`, so non-exportable / Secure-Enclave
  keys work too.
- **PDF container:** [PoDoFo](https://github.com/podofo/podofo) 1.x builds the CMS/PKCS#7
  signature, `/ByteRange`, and the incremental update. PoDoFo gets only the certificate
  and delegates the actual signing to a `SigningService` callback wired to `SecKeyCreateSignature`.
- **Signature type:** PAdES-B (ETSI.CAdES.detached), SHA-256. Output validates in
  poppler's `pdfsig` and Adobe.

## Architecture

```
SwiftUI (Swift)                         SigningEngine (Objective-C++)
  AppModel (@Observable)                  PdfSignerCms(certDER, params)
  ContentView  ── three states             params.SigningService = λ ───┐
  PDFPreview   ── drag to place box                                      │
  KeychainService ── lists identities      SecKeyCreateSignature(privKey,│
        │                                    .rsaSignatureDigestPKCS1v15  │
        └── PDFSigningEngine.signPDF(...) ──► SHA256, hash) ◄────────────┘
                                            SignDocument() → ByteRange + incremental update
```

The C++/Security glue lives entirely in `PDFSign/SigningEngine/PDFSigningEngine.mm`;
its public header is C++-free so Swift imports it via the bridging header.

## Build

Requires Xcode 26+ and Homebrew. PoDoFo is **statically linked** (per the
[PoDoFo static-linking guide](https://github.com/podofo/podofo/blob/master/README.md)),
so there's a one-time vendoring step that builds it from source:

```bash
brew install xcodegen cmake
./scripts/build-podofo.sh      # builds vendor/podofo/lib/libpodofo_bundle.a (one-time)
xcodegen generate
open PDFSign.xcodeproj         # or: xcodebuild -scheme PDFSign -configuration Debug build
```

`scripts/build-podofo.sh` builds PoDoFo 1.1.0 with `PODOFO_BUILD_STATIC=TRUE` +
`PODOFO_BUILD_LIB_ONLY=TRUE`, then `libtool`-merges PoDoFo and all of its static
dependencies (OpenSSL, freetype, fontconfig, gettext, libpng/tiff/jpeg, brotli, lzma,
zstd) into a single `libpodofo_bundle.a`. The app links that archive plus a handful of
**system** libraries (`libxml2`, `z`, `bz2`, `expat`, `iconv`) and `CoreFoundation`, with
`PODOFO_STATIC` defined. Nothing is copied into the `.app` — there's no `Frameworks` dir
and **zero `/opt/homebrew` runtime dependency**:

```bash
otool -L PDFSign.app/Contents/MacOS/PDFSign.debug.dylib | grep opt/homebrew   # (empty)
```

`vendor/` is git-ignored; re-run the script to update PoDoFo (bump `PODOFO_VERSION`).

## TODO (distribution)

The dev build runs ad-hoc-signed with App Sandbox and Hardened Runtime **off**. Before
distributing:

- Enable **App Sandbox** (`com.apple.security.files.user-selected.read-write`) and
  **Hardened Runtime** (static linking means there are no nested dylibs to sign).
- Sign the app with a **Developer ID** identity, then **notarize**
  (the `asc-notarization` workflow applies).
- Consider **RFC 3161 timestamps** (TSA) and **PAdES LTV** — currently out of scope.
- Multi-signature, signature validation UI, and certification flags are out of scope.

## Notes / gotchas (hard-won)

- PoDoFo's `Rect` collides with the legacy QuickDraw `Rect` from `MacTypes.h` — qualify
  `PoDoFo::Rect`.
- `PdfDate()` defaults to the **epoch**; use `PdfDate::UtcNow()`.
- Static linking pulls in transitive deps the linker won't auto-find: `libintl` (gettext,
  via fontconfig) and `CoreFoundation` (via gettext) are the non-obvious ones.
- The build needs `vendor/podofo/` present — run `scripts/build-podofo.sh` first or the
  link fails with a missing-archive error.
