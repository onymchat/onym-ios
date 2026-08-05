# Postmortem — member removal (iOS), PR #208

**Status:** closed unmerged on 2026-08-05, in step with
[onymchat/onym-android#192](https://github.com/onymchat/onym-android/pull/192).

That Android postmortem holds the full account — the wire format, all five
review rounds, the two open correctness defects, and the process lessons.
**Read it first.** This note covers only what was iOS-specific.

Branch `feature/member-removal` is left in place (head `ced0718`); nothing is
deleted.

## State at close

Rounds 1–4 of the Android review are mirrored and pushed; the full
`OnymIOSTests` target was green at 917 tests, 0 failures.

Round 5 — removal surviving screen teardown, the broadened apply lock, the
avatar-broadcaster gate — was **in progress and left uncommitted in the working
tree**, including a partial `GroupRemovalFlow.swift` extraction. It was not a
coherent state to build on, and was discarded rather than committed. Anyone
re-landing starts that round from scratch.

## Open defects

Both open defects from the Android postmortem apply here identically, because
this side is a faithful mirror. Neither is fixed on either platform.

1. **`statusEpoch` does not advance when the boolean membership state is
   unchanged.** See `Sources/OnymIOS/Group/MemberProfile.swift` and the epoch
   handling in `Sources/OnymIOS/Group/JoinRequestApprover.swift`.
2. **`removal_member_bls_hex` is not bound to the verified on-chain
   commitment.** See `Sources/OnymIOS/Group/MemberRemovalPayload.swift:85`.

## What iOS did better — worth preserving in a re-land

- **Test fixtures computed real Poseidon commitments** via the simulator FFI
  (`makeRealTyrannyCommitment`, in `Tests/OnymIOSTests/`) instead of stubbing
  the chain reader out. Android took the weaker route of `chainState = null`
  for the same tests. Same intent, strictly stronger coverage — and notably,
  the harder-to-fake fixture is what open defect (2) will need.
- **Every mirrored fix was neuter-verified**: the fix was temporarily removed
  and the test watched to fail. This caught that one of the announcement-guard
  tests was belt-and-braces only — it still passed with the guard removed,
  because `verifyTyrannyInvitation` rejects the payload later anyway. That was
  reported rather than quietly counted as coverage.
- **The concurrency test was reshaped to match production topology** after a
  first attempt passed for the wrong reason. Two dispatcher instances each mint
  their own apply lock, so the race was unrepresentable. Production builds
  exactly one dispatcher for the inbox pump, and the retry path re-enters that
  same value. Carry this forward as a known footgun.

## Structural differences from Android (not gaps)

- **No schema migration.** `statusEpoch` lives inside the already-encrypted
  `memberProfilesJSON` blob, so unlike Android's Room column there is no
  `DEFAULT`-drift hazard and no migration test to mirror.
- **Removal UI state was already screen-scoped** — `@State` on a
  `ChatMembersView` bound to one group id — so Android's cross-group
  error-dialog bug was structurally impossible. Android's round-5 fix moved
  that state app-side for a different reason (surviving dismissal mid-flight),
  which is exactly the part left unfinished here.
- **Two genuine iOS-only bugs surfaced** from the Android sweep of
  tombstone-aware read sites: `ChatsView`'s row subtitle counted the full
  profile map, and the UIKit empty-state listed removed members' aliases.

## Follow-on

Convergence work — persisted resend queue, pre-send epoch sync, traffic keyed
to the rotated secret — is tracked in
[onymchat/onym-android#193](https://github.com/onymchat/onym-android/issues/193)
and applies to both platforms.
