# Compliance PDFs

Submission-ready PDFs and their HTML sources.

- `france-encryption-declaration.pdf` — upload in App Store Connect
  (App Information → App Encryption Documentation). ASC forwards it to ANSSI.
- `us-self-classification-report.pdf` — email to `crypt@bis.doc.gov` and
  `enc@nsa.gov`.

The PDFs carry the declarant's real details and a typed signature. Keep the
`.md` files one level up as the plain-text source of truth; these HTML/PDFs
are the formatted, personal-data-filled artifacts for actual submission.

## Regenerate

Edit the `.html`, then render with headless Chrome:

```bash
cd docs/compliance/pdf
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for b in france-encryption-declaration us-self-classification-report; do
  PROF=$(mktemp -d)
  "$CHROME" --headless=new --disable-gpu --no-sandbox --no-pdf-header-footer \
    --user-data-dir="$PROF" --print-to-pdf="$b.pdf" "file://$PWD/$b.html"
  rm -rf "$PROF"
done
```
