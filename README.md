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

Requires Xcode 26+, and Homebrew packages used at build time:

```bash
brew install xcodegen podofo dylibbundler
xcodegen generate
open PDFSign.xcodeproj        # or: xcodebuild -scheme PDFSign -configuration Debug build
```

PoDoFo and its dependency chain (OpenSSL, freetype, fontconfig, libpng/tiff/jpeg, …) are
**bundled into the .app** at build time by a post-build script (`dylibbundler`), rewriting
load paths to `@executable_path/../Frameworks`. The shipped app has **zero `/opt/homebrew`
runtime dependency** — verify with:

```bash
otool -L PDFSign.app/Contents/MacOS/PDFSign.debug.dylib | grep opt/homebrew   # (empty)
```

## TODO (distribution)

The dev build runs ad-hoc-signed with App Sandbox and Hardened Runtime **off** so the
bundled (ad-hoc-signed) dylibs load. Before distributing:

- Enable **App Sandbox** (`com.apple.security.files.user-selected.read-write`) and
  **Hardened Runtime**.
- Re-sign every bundled dylib **and** the app with a **Developer ID** identity, then
  **notarize** (the `asc-notarization` workflow applies).
- Consider **RFC 3161 timestamps** (TSA) and **PAdES LTV** — currently out of scope.
- Multi-signature, signature validation UI, and certification flags are out of scope.

## Notes / gotchas (hard-won)

- PoDoFo's `Rect` collides with the legacy QuickDraw `Rect` from `MacTypes.h` — qualify
  `PoDoFo::Rect`.
- `PdfDate()` defaults to the **epoch**; use `PdfDate::UtcNow()`.
- `dylibbundler` needs `-Wl,-headerpad_max_install_names` on the linked binary, and the
  build script is idempotent so incremental builds don't re-run it.
- In Debug, Xcode links into `PDFSign.debug.dylib` (not the stub exe); the bundler targets
  whichever binary actually references Homebrew.
