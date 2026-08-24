# OnymDesignTokens

The swappable look of the Onym app. This package holds token *values*
only: color, corner radius, typeface. It has no dependencies, defines
no components, and knows nothing about the app.

Everything visual in `OnymDesign` and the eight UI packages reads from
here, so replacing this one module restyles the whole app without
touching a line of app code.

## What is in the contract

| Symbol | What it is |
| --- | --- |
| `OnymTokens` | 17 colors: surfaces, text ramp, hairlines, semantic green/red/amber, `onAccent`, `onTile`, `lightbox`, `scrim`(`UI`) |
| `OnymAccent` | The 6-case identity accent palette, `.color` per case |
| `OnymTile` | The 9 icon-tile hues — the design system's `--on-tile-*` family |
| `OnymTerminal` | The pinned-dark console block: surface, deep, phosphor text, ink, two overlays |
| `OnymTint` | Pastel fills and the deep inks that read on them — hero tiles, the amber notice, governance badges |
| `OnymRadius` | 10 corner steps — `card` `field` `panel` `hero` `inset` `control` `badge` `tile` `chip` `pill` — plus `shape(_:)` |
| `OnymType` | `font(size:weight:)`, `mono(size:weight:)`, `fixed(size:weight:)`, `scale(_:)` — the text and mono faces, and the reader's size setting |
| `Color.dynamic(light:dark:)` | Helper for declaring a color that follows the system trait collection |

Radius steps are named for what they wrap, not what they measure. An
adopter setting `inset` to 16 should not need to know it used to be 12.

`OnymType` carries no size scale on purpose — sizes still arrive from
the call site. Swapping the typeface is three function bodies; imposing
a scale on 470 call sites is a design decision, not a packaging one.

`font` and `mono` honour Dynamic Type; `fixed` deliberately does not,
and is for SF Symbols used as artwork inside boxes drawn at a set size.
If you replace the bodies, keep the scaling — dropping it turns Dynamic
Type off for the whole app.

One trap worth inheriting the answer to: the scaling is applied as a
**ratio**, not by passing the size to `UIFontMetrics.scaledFont(for:)`.
That method rounds to whole points *at the default text size* — 11.5pt
comes back 12pt — and the app spends around sixty half-point sizes.

Anything else — `OnymMark`, `OnymGovIcon`, the `Settings*` components,
`OnymAccent.forSender(blsPubkeyHex:)` — lives in `OnymDesign` and is
**not** yours to reimplement. Sender-to-accent mapping in particular is
policy, not a token: adopters inherit it unchanged.

One colour in the app is still not from here: `Color.accentColor`, the
system tint, which comes from the app's asset catalog. It is already
adopter-controlled, just through a different door.

## How to ship a differently styled build

1. Copy this directory to your own package, keeping the module name
   `OnymDesignTokens` and the product name `OnymDesignTokens`. The name
   is load-bearing — it is what the rest of the graph imports.
2. Change the values. Keep every symbol in the table above, with the
   same names and types.
3. Repoint the dependency in `Packages/OnymDesign/Package.swift` at your
   copy:

   ```swift
   dependencies: [
       .package(path: "../AcmeOnymTokens")   // instead of ../OnymDesignTokens
   ]
   ```

   or, if you consume Onym as a git dependency, use SwiftPM's
   `--replace-scm-with-local` / a `.package(name:path:)` override.
4. Build. That is the whole swap.

### Checking your copy before you wire it in

`OnymDesignTokensTests` exercises the whole contract and can be run
against a replacement module directly:

```
cd YourTokensPackage
xcodebuild test -scheme OnymDesignTokens \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

It checks that every token resolves in both appearances, that the
surface ramp does not collapse, that no two accents come out the same
colour, that the radius scale stays ordered, and that the palette clears
its contrast floors. That last one is the point: a theme that fails it
is not a theme, it is an accessibility regression.

### The completeness guarantee

There is no protocol to conform to and no registration call, because
none is needed: the app refers to these tokens by name from 758 call
sites. A replacement module that omits `text3`, or types it as
`UIColor` instead of `Color`, fails to compile. You cannot ship a
half-finished theme by accident.

### What this seam does *not* give you

Swapping is a **build-time** choice, not a runtime one. There is no
in-app theme picker and no way to change tokens without recompiling.
That is the deliberate trade for compile-time completeness and zero
indirection on every color read. Light and dark still switch live at
runtime, as before — that is inside each token, not across modules.

## Keeping in step with the design system

Values here mirror the `Onym Design System` project on claude.ai.
These divergences are intentional and should survive any resync — the
contrast tests will fail if a resync undoes one:

- **`amber` light variant is `#B25E00`,** not the system orange
  `#FF9500`. The original fails WCAG AA (~2.1:1) at the caption size it
  is used on, and it is used on lines a founder is most expected to
  read.
- **`OnymTint.orangeInk` is `#BE4300`,** not `#D14A00`. The original
  measured 4.00:1 on its own pastel and 3.85:1 on the 16% tint — the
  same failure as amber, found by the contrast suite rather than by
  hand.
- **`text3` dark is 0.40 alpha** against light's 0.42 — the darker
  ground needs slightly less fade to hold the same apparent contrast.
- **The radius scale has ten steps, not the design system's five.** The
  app was already spending fifteen distinct corners and `inset` (12) is
  its single most common; the system had no word for it.

### One known shortfall

White glyphs on four of the nine `OnymTile` hues sit below WCAG
1.4.11's 3:1 for non-text contrast — amber 2.20, teal 2.48, orange
2.60, green 2.69. This is Apple's Settings palette drawn the way
Settings draws it, and every tile sits beside a `Row` whose title
carries the same meaning in text, so nothing is knowable only from the
tile. `testOnTileStaysLegibleOnEveryTile` holds a regression floor
rather than claiming conformance. If a tile ever becomes the only cue
for something, raise that floor and darken the palette to meet it.
