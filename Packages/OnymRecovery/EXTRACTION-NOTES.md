# OnymRecovery extraction notes

## Files moved (from `Sources/OnymIOS/Recovery/` via plain `mv`)

- `BiometricAuthenticator.swift`
- `RecoveryPhraseBackupFlow.swift`
- `RecoveryPhraseBackupView.swift`

The now-empty `Sources/OnymIOS/Recovery/` directory was removed.

## Dependency trims

Listed candidates were OnymIdentity, OnymFoundation, OnymDesign. Kept only:

- **OnymIdentity** — `RecoveryPhraseBackupFlow` uses `IdentityRepository` and `Identity`
  (`import OnymIdentity` was already present in the file; no new imports needed).

Trimmed:

- **OnymFoundation** — nothing from it (Bip39, SecureRandom, StellarStrKey, StorageEncryption,
  ContractsTrust) is referenced by these files.
- **OnymDesign** — the view uses plain SwiftUI/UIKit colors and SF Symbols; no OnymBrand /
  SettingsDesign / SettingsQRCode usage.

System frameworks used: Foundation, LocalAuthentication, UIKit, UniformTypeIdentifiers, SwiftUI.

## Public surface (symbol → justifying external consumer)

### BiometricAuthenticator.swift

- `public protocol BiometricAuthenticator` (+ its `authenticate(reason:)` requirement) —
  type annotations in `Sources/OnymIOS/OnymIOSApp.swift` (lines 52, 747, 757); conformed to by
  `FakeAuthenticator` in `Tests/OnymIOSTests/RecoveryPhraseBackupFlowTests.swift`.
- `public struct LAContextAuthenticator` — constructed in `OnymIOSApp.swift` and in tests.
  - `public init(failClosed:canEvaluate:)` — tests pass both parameters; the app uses defaults.
  - `public static let failClosedByDefault` — asserted directly in tests (lines 180, 185).
  - `public func authenticate(reason:)` — required as witness to the public protocol; also
    called directly in tests (lines 162, 174).
  - `failClosed` stored property stays internal (never read outside; set via init only).
- `public struct AlwaysAcceptAuthenticator` (DEBUG-only) — constructed in `OnymIOSApp.swift`
  line 758 under `--mock-biometric`; explicit `public init() {}` added (memberwise is internal).
- `BiometricAuthError` — **internal**. Tests only assert the localized message string, never
  the type.
- `LAContext.evaluatePolicyAsync` extension — stays `private`.

### RecoveryPhraseBackupFlow.swift

- `public final class RecoveryPhraseBackupFlow` — constructed in `OnymIOSApp.swift` and tests;
  referenced in `AppDependencies.swift`, `SettingsView.swift`, `RootView.swift`.
  - `public init(repository:authenticator:pasteboard:clipboardClearDelay:verifyAdvanceDelay:)` —
    app uses the 3 defaulted params; tests pass all five.
  - Public members, each used by `Tests/OnymIOSTests/RecoveryPhraseBackupFlowTests.swift`:
    `step`, `isReady`, `start()`, `stop()`, `authenticate()`, `dismissedAuthError()`,
    `tappedReveal()`, `tappedCopyPhrase()`, `tappedContinueFromReveal()`, `picked(word:)`,
    `tappedDoneFromCompletion()`.
  - `tappedContinueFromIntro()` — **internal**: only called by `RecoveryPhraseBackupView`,
    which now lives in this same package.
  - `public enum Step`, `public enum VerifyState` — pattern-matched/compared throughout tests.
  - `public struct VerifyRound` with `public let wordPosition/correct/options` — fields read in
    tests; memberwise init left internal (never constructed outside).
- `public protocol PasteboardWriter` (+ both requirements) — `FakePasteboard` in tests conforms;
  also appears in the public init signature.
- `public struct UIPasteboardWriter` + `public init()` + public methods — not referenced by name
  outside the package, BUT it is the default argument value of the public flow init
  (`pasteboard: PasteboardWriter = UIPasteboardWriter()`), and Swift forbids internal
  declarations in default arguments of public functions; the app relies on that default.
  Methods are public as witnesses to the public protocol.
- `Duration.seconds` extension — stays `private`.

### RecoveryPhraseBackupView.swift

- `public struct RecoveryPhraseBackupView` with `public init(flow:)` and `public var body` —
  instantiated in `Sources/OnymIOS/Settings/SettingsView.swift` line 184.
- All screen subviews (`IntroScreen`, `RevealScreen`, `VerifyScreen`, `VerifyOption`,
  `ProgressDots`, `DoneScreen`, `RoundedIcon`) stay `private`.

Public top-level symbols: 7 (BiometricAuthenticator, LAContextAuthenticator,
AlwaysAcceptAuthenticator, RecoveryPhraseBackupFlow, PasteboardWriter, UIPasteboardWriter,
RecoveryPhraseBackupView).

## Ambiguities / decisions

- `AlwaysAcceptAuthenticator` remains wrapped in `#if DEBUG`; its consumer (`OnymIOSApp`) also
  references it only under DEBUG, so this stays correct across build configs.
- Tests (`Tests/OnymIOSTests/RecoveryPhraseBackupFlowTests.swift` and the UI tests) will need
  `import OnymRecovery` (and `@testable` removal is unnecessary — everything they use is now
  public) at the integration step; consumers in `Sources/OnymIOS` will likewise need
  `import OnymRecovery`. Not done here per instructions (do not touch consumers).
- `LAContextAuthenticator.canEvaluate` closure parameter exposes `LAContext` (LocalAuthentication)
  in the public init signature — acceptable since LocalAuthentication is a system framework.
