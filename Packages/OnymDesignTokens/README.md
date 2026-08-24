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
| `OnymTokens` | 13 theme-adaptive colors: surfaces, text ramp, hairlines, semantic green/red/amber, `onAccent` |
| `OnymAccent` | The 6-case identity accent palette, `.color` per case |
| `OnymRadius` | 10 corner steps — `card` `field` `panel` `hero` `inset` `control` `badge` `tile` `chip` `pill` — plus `shape(_:)` |
| `OnymType` | `font(size:weight:)` and `mono(size:weight:)` — the text and mono faces |
| `Color.dynamic(light:dark:)` | Helper for declaring a color that follows the system trait collection |

Radius steps are named for what they wrap, not what they measure. An
adopter setting `inset` to 16 should not need to know it used to be 12.

`OnymType` carries no size scale on purpose — sizes still arrive from
the call site. Swapping the typeface is two function bodies; imposing a
scale on 465 call sites is a design decision, not a packaging one.

Anything else — `OnymMark`, `OnymGovIcon`, the `Settings*` components,
`OnymAccent.forSender(blsPubkeyHex:)` — lives in `OnymDesign` and is
**not** yours to reimplement. Sender-to-accent mapping in particular is
policy, not a token: adopters inherit it unchanged.

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
Two divergences are intentional and should survive any resync:

- **`amber` light variant is `#B25E00`,** not the system orange
  `#FF9500`. The original fails WCAG AA (~2.1:1) at the caption size it
  is used on, and it is used on lines a founder is most expected to
  read.
- **`text3` dark is 0.40 alpha** against light's 0.42 — the darker
  ground needs slightly less fade to hold the same apparent contrast.
