fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios release

```sh
[bundle exec] fastlane ios release
```

Ad-hoc IPA for GitHub Release

### ios screenshots

```sh
[bundle exec] fastlane ios screenshots
```

Generate localized App Store screenshots via the UI-test harness



Drives the app through fastlane snapshot (see fastlane/Snapfile):

the ScreenshotUITests flow runs on the offline --ui-loopback

harness, seeds a group + conversation, and captures every screen

in each configured language. Output → fastlane/screenshots/

(git-ignored). Upload separately with the deliver lane once you're

happy (set skip_screenshots: false there).

### ios upload_metadata

```sh
[bundle exec] fastlane ios upload_metadata
```

Upload App Store metadata to App Store Connect (no binary, no screenshots)



Reads an App Store Connect API key from the environment:

  ASC_KEY_ID              — the key's Key ID

  ASC_ISSUER_ID           — your App Store Connect Issuer ID

  ASC_KEY_PATH            — path to the .p8 file            (or…)

  ASC_KEY_CONTENT         — the .p8 contents, inline        (use in CI)

  ASC_KEY_CONTENT_BASE64  — 'true' if ASC_KEY_CONTENT is base64-encoded

  ASC_APP_VERSION         — optional; the version whose metadata to edit



Metadata lives in fastlane/metadata/ (committed). Screenshots are

out of scope and skipped; no binary is uploaded and nothing is

submitted for review — this only pushes the listing text.

### ios upload_all

```sh
[bundle exec] fastlane ios upload_all
```

Upload App Store metadata AND screenshots to App Store Connect



Same App Store Connect API key env vars as upload_metadata:

  ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH (or ASC_KEY_CONTENT

  [+ ASC_KEY_CONTENT_BASE64]) / optional ASC_APP_VERSION.



Pushes the committed metadata (fastlane/metadata) plus the

generated screenshots (fastlane/screenshots — run the screenshots

lane first). No binary is uploaded and nothing is submitted for

review.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
