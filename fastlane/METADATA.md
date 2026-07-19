# App Store metadata (fastlane deliver)

The App Store listing text lives in `fastlane/metadata/` and is committed
to the repo. The `upload_metadata` lane pushes it to App Store Connect.
**Screenshots are out of scope** — they're skipped, no binary is
uploaded, and nothing is submitted for review. This only updates the
listing text.

## What's here

```
fastlane/metadata/
  copyright.txt                app-level fields (categories, copyright)
  primary_category.txt         SOCIAL_NETWORKING
  secondary_category.txt       UTILITIES
  review_information/notes.txt  how App Review can test a no-account app
  en-US/                       English (US) listing
  ru/                          Russian listing
    name.txt subtitle.txt description.txt keywords.txt
    promotional_text.txt release_notes.txt
    support_url.txt marketing_url.txt privacy_url.txt
```

## How to upload

Provide an **App Store Connect API key** (Users and Access → Integrations
→ App Store Connect API → generate a key with the *App Manager* role).
You get an Issuer ID, a Key ID, and a one-time `AuthKey_<KEYID>.p8`
download. **Do not commit the `.p8`** — it's git-ignored.

Point the lane at the key via environment variables, then run it:

```sh
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_PATH=/absolute/path/to/AuthKey_XXXXXXXXXX.p8
# optional: the version whose metadata to edit (defaults to the editable one)
# export ASC_APP_VERSION=1.0

bundle exec fastlane upload_metadata
```

In CI, pass the key inline instead of a path:

```sh
export ASC_KEY_CONTENT="$(cat AuthKey_XXXXXXXXXX.p8)"   # or base64
# export ASC_KEY_CONTENT_BASE64=true
```

## Before your first submission — verify

The listing text is authored and ready, but a few values point at
resources you should confirm exist / are correct for your account:

- `marketing_url.txt` → https://onym.app
- `support_url.txt`   → https://github.com/onymchat/onym-ios/issues
- `privacy_url.txt`   → https://onym.app/privacy  (App Review **requires**
  a reachable privacy policy — make sure this page is live)
- `copyright.txt`     → "2026 Onym" (adjust holder/year if needed)
- App Review contact (name / email / phone) is **not** committed here;
  set it in App Store Connect (or add `review_information/first_name.txt`
  etc. if you prefer to manage it in-repo).

Category enums use App Store Connect's values (e.g. `SOCIAL_NETWORKING`,
`UTILITIES`); change them in the app-level `*.txt` files if you disagree.
