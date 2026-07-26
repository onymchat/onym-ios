# Onym App Store marketing screenshots

Five English and five Russian App Store compositions, each 1320×2868.
Original Fastlane screenshots are not modified.

## Story

1. Identity stays on the user's device.
2. The messenger UI is open source and can be self-built.
3. Nostr is the courier; the user can run the relay.
4. Stellar is the notary, separate from identity and message transport.
5. The user can own the complete path without a company in the middle.

## Visual system

The layout follows the light theme on [onym.app](https://onym.app):
`#f5f5f7` background, `#0a0a0a` foreground, `#6e6e73` secondary text,
SF Pro display typography, SF Mono labels, thin hairlines, and no decorative
campaign artwork. Screenshots are placed inside a rendered iPhone shell with
rounded screen clipping, side controls, edge highlights, and Dynamic Island.

## Rebuild

```sh
node marketing/screenshots/build-marketing.mjs
```

The renderer requires macOS Quick Look and `/opt/homebrew/bin/ffmpeg`.
