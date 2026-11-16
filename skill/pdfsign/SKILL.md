---
name: pdfsign
description: Digitally sign PDFs on this Mac with a certificate from the macOS Keychain using the PDFSign app's `pdfsign` command — find where a document expects a signature, place signature/date/text fields, preview them, then sign or hand the document to the user to review and sign in the app. Use when the user asks to sign a PDF, fill in a signature field, add a digital/qualified signature, or prepare a document for signing.
---

# PDFSign

`pdfsign` is the command-line face of the PDFSign app. Every command prints JSON on stdout;
on failure it exits 1 and prints `{"error": "…"}`. The private key never leaves the Keychain.

If `pdfsign` isn't on PATH, use `/Applications/PDFSign.app/Contents/MacOS/PDFSign` (same
commands), and tell the user they can add the command with **PDFSign → Install Command Line
Tool & Agent Skill…**. `pdfsign help` is the full reference, including the fields format.

## Signing is the user's decision

A digital signature can be legally binding (qualified certificates are equivalent to a
handwritten signature in the EU). So:

- **Default to `review`**: it opens the document in PDFSign with your fields placed, and the
  user checks and signs it themselves. Use `sign` only when the user explicitly asked you to
  sign without them looking, and has confirmed which document and which certificate.
- Never pick a certificate on your own when there's more than one — list them and ask.
- Never write over the input; `sign` writes a new file (`--out`) and refuses to overwrite
  unless you pass `--overwrite`, which needs the user's go-ahead.

## Workflow

1. **Understand the document**
   - `pdfsign inspect doc.pdf` — pages (displayed size, rotation) and form fields. An entry
     with `"type": "signature", "signed": false` is where the document expects a signature.
   - `pdfsign find doc.pdf "Signature"` (or "Podpis", "Date:", the signer's name…) to locate
     signature lines when there's no form field; `pdfsign text doc.pdf --page N` for context.
2. **Propose fields** (JSON, inline or a file):
   - An existing empty signature field: `{"type":"signature","field":"ClientSignature"}`
   - Otherwise place by rect, in PDF points on the page as displayed, origin bottom-left,
     pages 1-based: `{"type":"signature","page":2,"rect":[350,90,180,60]}`
   - Optional: `{"type":"date","page":2,"rect":[350,70,90,16],"format":"d. M. yyyy"}`,
     `{"type":"text","page":2,"rect":[72,70,160,16],"text":"Ljubljana"}`
   - Put a signature *above* a found "Signature" line: its rect's `y` ≈ the label's top.
3. **Check visually**: `pdfsign render doc.pdf --page 2 --fields '<json>' --out /tmp/p2.png`,
   then look at the PNG. The grid is labelled in the same coordinates. Adjust and re-render
   until each field sits on its line without covering text.
4. **Certificate**: `pdfsign identities` → confirm one with the user; pass its `fingerprint`
   (or a unique ≥ 8-char prefix) as `--identity`. Skip expired ones.
5. **Finish**
   - Review (default): `pdfsign review doc.pdf --fields '<json>' --identity <fp> --note "…"`.
     Tell the user the document is waiting in PDFSign.
   - Sign (only when told to): `pdfsign sign doc.pdf --out doc-signed.pdf --identity <fp>
     --fields '<json>'`. The Keychain may ask the user to allow access to the key.

One signature covers every field placed in the same run. At most one existing form field can
be filled per run; to add a second signature, sign the signed output again.

## Stamp appearance

`sign` uses the app's saved stamp settings (drawn signature image, date line, custom text).
Override with `--stamp-image file.png | --no-stamp-image`, `--stamp-date | --no-stamp-date`,
`--stamp-text "…"`, plus optional `--reason` / `--location` stored in the signature.
