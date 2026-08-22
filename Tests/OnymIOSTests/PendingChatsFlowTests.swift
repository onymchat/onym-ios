import XCTest
@testable import OnymInbox
@testable import OnymGroup
@testable import OnymIdentity
@testable import OnymChain

/// The flow behind the pending rows in the chats list. It folds three
/// sources into one row per chat-in-progress, so most of what matters
/// here is which source wins and when a row stops existing.
@MainActor
final class PendingChatsFlowTests: XCTestCase {

    private let owner = IdentityID()

    // MARK: - Offers

    func test_offer_becomesAnAcceptableRow() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        await harness.repository.record(harness.makeChat())

        try await waitFor { harness.flow.rows.count == 1 }
        let row = try XCTUnwrap(harness.flow.rows.first)
        XCTAssertEqual(row.state, .offered)
        XCTAssertEqual(row.name, "Maple Garden")
        XCTAssertEqual(row.inviterAlias, "Alice")
        XCTAssertTrue(row.isDismissable)
    }

    func test_acceptingAnOffer_sendsOnlyOnceConfirmed() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        try await waitFor { harness.flow.rows.count == 1 }

        // Preparing the screen is not sending. Accept is a tap on a row
        // that only a real inbound offer can create, and it still shows
        // what is about to be disclosed before anything leaves.
        let prepared = await harness.flow.prepareAccept(rowID: chat.id)
        let confirmation = try XCTUnwrap(prepared)
        XCTAssertEqual(confirmation.groupName, "Maple Garden")
        XCTAssertEqual(confirmation.inviterAlias, "Alice")
        XCTAssertEqual(confirmation.introPublicKey, chat.introPublicKey)
        XCTAssertEqual(
            confirmation.suggestedLabel, "Bob",
            "pre-filled with the identity's own alias"
        )
        var sent = await harness.sender.calls.count
        XCTAssertEqual(sent, 0)

        await harness.flow.confirmJoin(confirmation, label: "Bobby")

        try await waitForAsync { await harness.sender.calls.count == 1 }
        sent = await harness.sender.calls.count
        XCTAssertEqual(sent, 1)
        let calls = await harness.sender.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.capability.groupId, chat.groupID)
        XCTAssertEqual(call.label, "Bobby", "the name they typed, not the identity's")
        try await waitFor { harness.flow.rows.first?.state == .waiting }
    }

    func test_prepareAccept_onARowThatAlreadyAsked_offersNothing() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        await harness.repository.markRequested(id: chat.id)
        try await waitFor { harness.flow.rows.first?.state == .waiting }

        let confirmation = await harness.flow.prepareAccept(rowID: chat.id)

        XCTAssertNil(confirmation, "one tap, one request")
    }

    func test_accept_isDebouncedWhileTheSendIsInFlight() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.sender.hold()
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        try await waitFor { harness.flow.rows.count == 1 }

        let prepared = await harness.flow.prepareAccept(rowID: chat.id)
        let confirmation = try XCTUnwrap(prepared)
        await harness.flow.confirmJoin(confirmation, label: "Bob")
        await harness.flow.confirmJoin(confirmation, label: "Bob")

        // Wait on the *spy* being entered, not on `isSending`: that flag
        // is set synchronously inside `send` before `submitJoin` is ever
        // awaited, so releasing on it could unblock a gate nobody had
        // reached yet and prove nothing about the second tap.
        try await waitForAsync { await harness.sender.calls.count == 1 }
        XCTAssertTrue(harness.flow.rows.first?.isSending == true)
        await harness.sender.release()
        try await waitFor { harness.flow.rows.first?.state == .waiting }
        let sent = await harness.sender.calls.count
        XCTAssertEqual(sent, 1, "the second tap must not ship a second request")
    }

    func test_failedSend_showsTheReasonAndRetryResends() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.sender.setOutcome(.transportFailed("relay rejected"))
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        try await waitFor { harness.flow.rows.count == 1 }

        await harness.acceptThroughTheScreen(chat.id)
        // The transport's own words are deliberately not kept: the row
        // is on disk and outlives the language it was written in.
        try await waitFor { harness.flow.rows.first?.state == .sendFailed(.transport) }
        XCTAssertTrue(harness.flow.rows.first?.state.isRetryable == true)

        await harness.sender.setOutcome(.sent)
        harness.flow.retry(chat.id)

        try await waitFor { harness.flow.rows.first?.state == .waiting }
        let sent2 = await harness.sender.calls.count
        XCTAssertEqual(sent2, 2)
    }

    func test_noIdentityLoaded_leavesTheRowRetryableWithSomethingToRead() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.sender.setOutcome(.noIdentityLoaded)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        try await waitFor { harness.flow.rows.count == 1 }

        await harness.acceptThroughTheScreen(chat.id)

        try await waitFor { harness.flow.rows.first?.state == .sendFailed(.noIdentity) }
        XCTAssertTrue(harness.flow.rows.first?.state.isRetryable == true)
    }

    func test_malformedInvite_saysSoWithoutTouchingTheSender() async throws {
        // A capability that can't be rebuilt from the stored row: there
        // is nothing to send and nothing a Retry could fix, so the row
        // keeps its state and the error is the whole message.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let malformed = harness.makeChat(introPublicKey: Data([0x01]))
        await harness.repository.record(malformed)
        try await waitFor { harness.flow.rows.count == 1 }

        await harness.acceptThroughTheScreen(malformed.id)

        XCTAssertNotNil(harness.flow.lastError)
        let sends = await harness.sender.calls.count
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(harness.flow.rows.first?.state, .offered)

        harness.flow.dismissError()
        XCTAssertNil(harness.flow.lastError)
    }

    func test_dismiss_dropsTheRow() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        try await waitFor { harness.flow.rows.count == 1 }

        harness.flow.dismiss(chat.id)

        try await waitFor { harness.flow.rows.isEmpty }
    }

    // MARK: - Verification overlay

    func test_verification_winsOverTheStoredStatus() async throws {
        // Past the founder's approval, what the person is waiting on has
        // moved on from them — showing "waiting on the founder" then
        // would name someone who has already done their part.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        await harness.repository.markRequested(id: chat.id)
        try await waitFor { harness.flow.rows.first?.state == .waiting }

        await harness.verifications.record(makeVerification(
            groupIDHex: chat.groupIDHex, owner: owner, status: .unreachable
        ))

        try await waitFor { harness.flow.rows.first?.state == .founderUnreachable }
        XCTAssertEqual(harness.flow.rows.count, 1, "one row, not one per source")
    }

    func test_retry_onAStuckVerification_redrivesTheVerifier() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        // Requested first, because that is the only way a verification
        // for this row can exist: it follows the founder's approval.
        await harness.repository.markRequested(id: chat.id)
        await harness.verifications.record(makeVerification(
            groupIDHex: chat.groupIDHex, owner: owner, status: .chainUnreachable
        ))
        try await waitFor { harness.flow.rows.first?.state == .chainUnreachable }

        harness.flow.retry(chat.id)

        try await waitForAsync { await harness.verifierRetries.values == [chat.groupIDHex] }
        let sent0 = await harness.sender.calls.count
        XCTAssertEqual(sent0, 0, "a verification retry is not a re-send")
    }

    func test_chainSettling_offersNoRetry() async throws {
        // It clears itself. Offering an action implies the user is
        // holding it up.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        // Requested first, because that is the only way a verification
        // for this row can exist: it follows the founder's approval.
        await harness.repository.markRequested(id: chat.id)
        await harness.verifications.record(makeVerification(
            groupIDHex: chat.groupIDHex, owner: owner, status: .chainSettling
        ))

        try await waitFor { harness.flow.rows.first?.state == .chainSettling }

        // Not just "the enum says so": a Retry tapped here must reach
        // neither the verifier nor the sender.
        harness.flow.retry(chat.id)

        let retries = await harness.verifierRetries.values
        let sends = await harness.sender.calls.count
        XCTAssertTrue(retries.isEmpty)
        XCTAssertEqual(sends, 0)
    }

    func test_verifyingStatus_readsAsTheSameWaitAsAskingDoes() async throws {
        // Before and after the founder's approval are one wait to the
        // person doing the waiting, so they must not render differently.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        // Requested first, because that is the only way a verification
        // for this row can exist: it follows the founder's approval.
        await harness.repository.markRequested(id: chat.id)
        await harness.verifications.record(makeVerification(
            groupIDHex: chat.groupIDHex, owner: owner, status: .verifying
        ))

        try await waitFor { harness.flow.rows.first?.state == .waiting }
    }

    func test_chainNotConfigured_isRetryableAndSaysSoOnItsOwn() async throws {
        // Split from `chainUnreachable` because the remedy differs: this
        // one is usually a cold-launch race, and its Retry re-fetches
        // the lists rather than asking the founder for anything.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        // Requested first, because that is the only way a verification
        // for this row can exist: it follows the founder's approval.
        await harness.repository.markRequested(id: chat.id)
        await harness.verifications.record(makeVerification(
            groupIDHex: chat.groupIDHex, owner: owner, status: .chainNotConfigured
        ))
        try await waitFor { harness.flow.rows.first?.state == .chainNotConfigured }

        harness.flow.retry(chat.id)

        try await waitForAsync { await harness.verifierRetries.values == [chat.groupIDHex] }
    }

    func test_verificationWithNoOffer_stillGetsARow() async throws {
        // A stale invitation replayed onto a device that never asked in
        // this install. Without a row the group is stuck forever, hidden
        // from the list by design, with no screen left to surface it.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        await harness.verifications.record(makeVerification(
            groupIDHex: String(repeating: "ab", count: 32),
            owner: owner,
            status: .unreachable
        ))

        try await waitFor { harness.flow.rows.count == 1 }
        let row = try XCTUnwrap(harness.flow.rows.first)
        XCTAssertEqual(row.state, .founderUnreachable)
        XCTAssertFalse(row.isDismissable, "there is no stored offer under it to drop")
    }

    func test_askAgain_onAWaitingRow_resendsToTheFounder() async throws {
        // A request can be sent and never answered — a revoked link, or
        // one that died in a relay. Before this there was no way out but
        // swiping the row away.
        //
        // Seeded through the screen, because that is the only way a row
        // reaches `.requested` — and the name it asked under comes with
        // it.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        try await waitFor { harness.flow.rows.count == 1 }
        await harness.acceptThroughTheScreen(chat.id)
        try await waitFor { harness.flow.rows.first?.state == .waiting }
        XCTAssertTrue(harness.flow.rows.first?.state.isRetryable == true)

        harness.flow.retry(chat.id)

        try await waitForAsync { await harness.sender.calls.count == 2 }
        let retries = await harness.verifierRetries.values
        XCTAssertTrue(retries.isEmpty, "the founder is who this wait belongs to")
    }

    func test_askAgain_onARowFromBeforeTheScreen_asksUnderTheIdentityName() async throws {
        // Every row already on disk when this version installs has no
        // stored label: the field is new. Those rows asked under the
        // identity's own name, and they are the ones most likely to
        // need asking again, having sat through an update. A retry that
        // bailed on the missing label made "Ask again" a button that
        // did nothing for exactly them.
        //
        // Seeded the pre-#299 way — recorded and marked requested, with
        // no trip through the confirmation screen.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        await harness.repository.markRequested(id: chat.id)
        try await waitFor { harness.flow.rows.first?.state == .waiting }

        harness.flow.retry(chat.id)

        try await waitForAsync { await harness.sender.calls.count == 1 }
        let label = await harness.sender.calls.first?.label
        XCTAssertEqual(label, "Bob", "the name it asked under the first time")
        // And attached, so the next repeat says the same thing even if
        // the identity is renamed in between.
        try await waitForAsync {
            await harness.repository.currentChats().first?.joinerLabel == "Bob"
        }
    }

    func test_askAgain_whileVerifying_redrivesTheVerifierInstead() async throws {
        // Past the approval the wait has changed hands: asking the
        // founder again would achieve nothing, because they already
        // said yes.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        // The verification first, and waited for by the row it
        // synthesises on its own: `.requested` and "verifying" both
        // read as `.waiting`, so waiting on the state can't tell
        // whether the flow has seen the verification yet — and a retry
        // that ran before it had would ask the founder again, which is
        // the exact thing this test says doesn't happen.
        await harness.verifications.record(makeVerification(
            groupIDHex: chat.groupIDHex, owner: owner, status: .verifying
        ))
        try await waitFor { harness.flow.rows.first?.id == chat.groupIDHex }
        await harness.repository.record(chat)
        await harness.repository.markRequested(id: chat.id)
        try await waitFor {
            harness.flow.rows.count == 1 && harness.flow.rows.first?.state == .waiting
        }

        harness.flow.retry(chat.id)

        try await waitForAsync { await harness.verifierRetries.values == [chat.groupIDHex] }
        let sends = await harness.sender.calls.count
        XCTAssertEqual(sends, 0)
    }

    func test_anUnansweredOffer_keepsItsAcceptEvenWhileVerifying() async throws {
        // A verification describes a join that was asked for. An offer
        // has asked for nothing, and letting the overlay win there took
        // the Accept button away with no way to say yes.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        // Deliberately left unanswered: a stale verification arriving
        // over an offer must not decide what this row can do.
        await harness.verifications.record(makeVerification(
            groupIDHex: chat.groupIDHex, owner: owner, status: .unreachable
        ))
        try await waitFor { harness.flow.rows.count == 1 }

        XCTAssertEqual(harness.flow.rows.first?.state, .offered)
    }

    // MARK: - End of the wait

    func test_theGroupThatEndedTheWaitIsRememberedAfterTheRowIsGone() async throws {
        // The pending thread reads this to know where to go, and it is
        // derived from the group snapshot rather than from `rows` —
        // which may not have arrived when the first emission lands.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        try await waitFor { harness.flow.rows.count == 1 }

        await harness.groups.insert(harness.makeGroup(id: chat.groupIDHex))

        try await waitFor { harness.flow.materializedGroupID(for: chat.id) == chat.groupIDHex }
        XCTAssertTrue(harness.flow.rows.isEmpty)
    }

    func test_theRowDisappearsWhenTheGroupLands() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat()
        await harness.repository.record(chat)
        try await waitFor { harness.flow.rows.count == 1 }

        await harness.groups.insert(harness.makeGroup(id: chat.groupIDHex))

        try await waitFor { harness.flow.rows.isEmpty }
    }

    // MARK: - Joining from a link

    func test_aTappedLink_recordsNothingAndSendsNothing() async throws {
        // The security rule this screen exists for: the URL types are
        // exported, so anything on the device — or a page in a browser —
        // can deliver a capability. Delivery must not disclose this
        // identity's name or keys, and must not leave a row behind
        // either.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()

        let destination = await harness.flow.prepareJoin(capability: harness.capability())

        guard case .confirm(let confirmation) = destination else {
            return XCTFail("a link must resolve to a screen, got \(destination)")
        }
        XCTAssertEqual(confirmation.groupName, "Maple Garden")
        XCTAssertEqual(confirmation.introPublicKey, harness.capability().introPublicKey)
        let sent = await harness.sender.calls.count
        XCTAssertEqual(sent, 0)
        let stored = await harness.repository.currentChats()
        XCTAssertTrue(stored.isEmpty, "nothing may be persisted before a person says so")
        XCTAssertTrue(harness.flow.rows.isEmpty)
    }

    func test_theConfirmationArrivesPreFilledWithTheIdentitysName() async throws {
        // Joining is one tap. The name a person asks under is almost
        // always their own, so the field carries it already and Send is
        // the only thing left to do — typing your own name to get into a
        // chat is a question with a known answer.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()

        guard case .confirm(let confirmation) =
                await harness.flow.prepareJoin(capability: harness.capability())
        else { return XCTFail("expected a confirmation") }

        XCTAssertEqual(confirmation.suggestedLabel, "Bob")
    }

    func test_confirmingALink_recordsTheRowAndSendsUnderTheTypedName() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        guard case .confirm(let confirmation) =
                await harness.flow.prepareJoin(capability: harness.capability())
        else { return XCTFail("expected a confirmation") }

        let outcome = await harness.flow.confirmJoin(confirmation, label: "Bobby")

        XCTAssertEqual(outcome, .waiting(rowID: harness.makeChat().id))
        // The row is written before `confirmJoin` returns; the send runs
        // on its own task, so it is waited on rather than read.
        try await waitForAsync { await harness.sender.calls.count == 1 }
        let calls = await harness.sender.calls
        XCTAssertEqual(calls.map(\.label), ["Bobby"])
        try await waitFor { harness.flow.rows.first?.state == .waiting }
    }

    func test_theNameAskedUnderIsRememberedForTheNextAsk() async throws {
        // A re-send that fell back to the identity's alias would arrive
        // from a stranger — the founder is deciding partly on the name.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        guard case .confirm(let confirmation) =
                await harness.flow.prepareJoin(capability: harness.capability())
        else { return XCTFail("expected a confirmation") }
        await harness.flow.confirmJoin(confirmation, label: "Bobby")
        try await waitFor { harness.flow.rows.first?.state == .waiting }

        harness.flow.retry(harness.makeChat().id)

        try await waitForAsync { await harness.sender.calls.count == 2 }
        let calls = await harness.sender.calls
        XCTAssertEqual(calls.map(\.label), ["Bobby", "Bobby"])
    }

    func test_aSecondLinkAfterAsking_opensTheWaitWithoutAskingAgain() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        guard case .confirm(let confirmation) =
                await harness.flow.prepareJoin(capability: harness.capability())
        else { return XCTFail("expected a confirmation") }
        await harness.flow.confirmJoin(confirmation, label: "Bobby")
        try await waitFor { harness.flow.rows.first?.state == .waiting }

        let second = await harness.flow.prepareJoin(capability: harness.capability())

        XCTAssertEqual(second, .waiting(rowID: harness.makeChat().id))
        let sent = await harness.sender.calls.count
        XCTAssertEqual(sent, 1, "a second delivery is not a second request")
    }

    func test_aLinkOnAnUnansweredOffer_confirmsAgainstTheOffersDetails() async throws {
        // The dispatcher got there first, so the screen can name who
        // invited and what they wrote — and confirming answers that
        // offer rather than starting a second one.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let offered = harness.makeChat()
        await harness.repository.record(offered)
        try await waitFor { harness.flow.rows.first?.state == .offered }

        guard case .confirm(let confirmation) =
                await harness.flow.prepareJoin(capability: harness.capability())
        else { return XCTFail("an unanswered offer must still be confirmable") }
        XCTAssertEqual(confirmation.inviterAlias, "Alice")
        await harness.flow.confirmJoin(confirmation, label: "Bobby")

        try await waitFor { harness.flow.rows.first?.state == .waiting }
        let sends = await harness.sender.calls.count
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(harness.flow.rows.count, 1, "one waiting room, not two")
    }

    // MARK: - What gets signed

    func test_theRulesSigned_areTheOnesTheScreenShowed() async throws {
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        guard case .confirm(let confirmation) =
                await harness.flow.prepareJoin(capability: harness.capability(rules: "Be kind."))
        else { return XCTFail("expected a confirmation") }
        XCTAssertEqual(confirmation.rules, "Be kind.")

        await harness.flow.confirmJoin(confirmation, label: "Bobby")

        try await waitForAsync { await harness.sender.calls.count == 1 }
        let calls = await harness.sender.calls
        XCTAssertEqual(calls.first?.rules, "Be kind.")
        // Kept on the row, because "Ask again" months later has to
        // re-sign the same words and the capability is gone by then.
        let stored = await harness.repository.currentChats()
        XCTAssertEqual(stored.first?.invitationMessage, "Be kind.")
    }

    func test_aLinkOnAnUnansweredOffer_signsTheTextThatWasRead_andKeepsIt() async throws {
        // The screen resolves a link's rules ahead of a stored offer's,
        // so a row whose words differ must be brought up to what was
        // actually read — otherwise this send, and every "Ask again"
        // after it, attests to text nobody saw.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        await harness.repository.record(harness.makeChat(invitationMessage: "an older draft"))
        try await waitFor { harness.flow.rows.first?.state == .offered }

        guard case .confirm(let confirmation) = await harness.flow.prepareJoin(
            capability: harness.capability(rules: "the rules as shown")
        ) else { return XCTFail("an unanswered offer must still be confirmable") }
        XCTAssertEqual(confirmation.rules, "the rules as shown")
        await harness.flow.confirmJoin(confirmation, label: "Bobby")
        try await waitForAsync { await harness.sender.calls.count == 1 }
        try await waitFor { harness.flow.rows.first?.state == .waiting }

        harness.flow.retry(harness.makeChat().id)

        try await waitForAsync { await harness.sender.calls.count == 2 }
        let calls = await harness.sender.calls
        XCTAssertEqual(calls.map(\.rules), ["the rules as shown", "the rules as shown"])
        XCTAssertEqual(
            calls.map(\.label), ["Bobby", "Bobby"],
            "re-asking introduces the same person the first ask did"
        )
    }

    func test_rulesThatAreOnlyWhitespace_askNothingAndSignNothing() async throws {
        // `"   "` is non-nil, and left alone it drew an empty rules
        // card and a mandatory tick — then signed nothing, because the
        // sender normalizes before signing.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat(invitationMessage: "   ")
        await harness.repository.record(chat)
        try await waitFor { harness.flow.rows.first?.state == .offered }

        guard let confirmation = await harness.flow.prepareAccept(rowID: chat.id)
        else { return XCTFail("expected a confirmation") }
        XCTAssertNil(confirmation.rules)

        await harness.flow.confirmJoin(confirmation, label: "Bobby")

        try await waitForAsync { await harness.sender.calls.count == 1 }
        let calls = await harness.sender.calls
        XCTAssertNil(calls.first?.rules)
    }

    func test_aLinkIntoAChatYouAreIn_opensItWithoutDisclosingAnything() async throws {
        let harness = await Harness.make(owner: owner)
        let capability = harness.capability()
        let hex = capability.groupId.map { String(format: "%02x", $0) }.joined()
        await harness.groups.insert(harness.makeGroup(id: hex))
        await harness.flow.start()

        let outcome = await harness.flow.prepareJoin(capability: capability)

        XCTAssertEqual(outcome, .alreadyJoined(groupIDHex: hex))
        let sent = await harness.sender.calls.count
        XCTAssertEqual(sent, 0)
    }

    func test_aLinkWithNoIdentity_saysSoRatherThanWaitingSilently() async throws {
        let harness = await Harness.make(owner: nil)
        await harness.flow.start()

        let outcome = await harness.flow.prepareJoin(capability: harness.capability())

        guard case .failed = outcome else {
            return XCTFail("expected a failure the caller can surface, got \(outcome)")
        }
        let sent0 = await harness.sender.calls.count
        XCTAssertEqual(sent0, 0)
    }

    // MARK: - Group rules

    func test_aLinkWithoutRules_signsNothing() async throws {
        // A group that asks nothing collects no agreement — and the
        // screen keeps its one tap.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()

        guard case .confirm(let confirmation) = await harness.flow.prepareJoin(
            capability: harness.capability()
        ) else { return XCTFail("expected the confirmation screen") }
        XCTAssertNil(confirmation.rules)
        await harness.flow.confirmJoin(confirmation, label: "Bob")

        try await waitForAsync { await harness.sender.calls.count == 1 }
        let signed = await harness.sender.calls.first?.rules
        XCTAssertNil(signed)
    }

    func test_aPushedOffer_signsTheRulesItArrivedWith() async throws {
        // A pushed invitation has no capability to read rules from:
        // they live on the stored offer, and reaching for the
        // capability's copy would sign text nobody was shown.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let chat = harness.makeChat(invitationMessage: "House rules apply.")
        await harness.repository.record(chat)
        try await waitFor { harness.flow.rows.count == 1 }

        let confirmation = await harness.flow.prepareAccept(rowID: chat.id)
        XCTAssertEqual(confirmation?.rules, "House rules apply.")
        await harness.flow.confirmJoin(try XCTUnwrap(confirmation), label: "Bob")

        try await waitForAsync { await harness.sender.calls.count == 1 }
        let signed = await harness.sender.calls.first?.rules
        XCTAssertEqual(signed, "House rules apply.")
    }

    func test_askAgain_reSignsTheSameRules() async throws {
        // A re-send months later has to say what the first one said.
        // The capability is long gone by then, so the row is where the
        // agreed text has to have survived.
        let harness = await Harness.make(owner: owner)
        await harness.flow.start()
        let capability = harness.capability(rules: "Be kind. No links.")
        guard case .confirm(let confirmation) = await harness.flow.prepareJoin(
            capability: capability
        ) else { return XCTFail("expected the confirmation screen") }
        await harness.flow.confirmJoin(confirmation, label: "Bob")
        try await waitFor { harness.flow.rows.first?.state == .waiting }

        harness.flow.retry(confirmation.rowID)

        try await waitForAsync { await harness.sender.calls.count == 2 }
        let resigned = await harness.sender.calls.last?.rules
        XCTAssertEqual(resigned, "Be kind. No links.")
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let repository: PendingChatRepository
        let verifications = PendingVerificationStore()
        let groups: GroupRepository
        let sender = SpyJoinSender()
        let verifierRetries = Recorder()
        let flow: PendingChatsFlow
        let owner: IdentityID?

        private init(owner: IdentityID?) {
            self.owner = owner
            let repository = PendingChatRepository(store: InMemoryPendingChatStore())
            self.repository = repository
            let groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
            self.groups = groups
            let sender = self.sender
            let retries = self.verifierRetries
            self.flow = PendingChatsFlow(
                repository: repository,
                verificationStore: verifications,
                groupRepository: groups,
                submitJoin: { capability, label, rules in
                    await sender.send(capability: capability, label: label, rules: rules)
                },
                displayLabel: { "Bob" },
                retryVerification: { hex in await retries.record(hex) },
                currentIdentityID: { owner }
            )
        }

        /// The only way to build one. The identity filter has to be in
        /// place before a test reads anything: fired off in an
        /// un-awaited `Task`, it raced every assertion that didn't
        /// happen to poll — `currentGroups()` is read synchronously, so
        /// that one test was deciding on a repository that had not been
        /// told whose groups it holds.
        static func make(owner: IdentityID?) async -> Harness {
            let harness = Harness(owner: owner)
            await harness.repository.setCurrentIdentity(owner)
            await harness.verifications.setCurrentIdentity(owner)
            await harness.groups.setCurrentIdentity(owner)
            return harness
        }

        /// Accept as a person performs it: open the screen, then Send.
        func acceptThroughTheScreen(_ rowID: String, label: String = "Bob") async {
            guard let confirmation = await flow.prepareAccept(rowID: rowID) else { return }
            await flow.confirmJoin(confirmation, label: label)
        }

        func capability(rules: String? = nil) -> IntroCapability {
            try! IntroCapability(
                introPublicKey: Data(repeating: 0x44, count: 32),
                groupId: Data(repeating: 0x11, count: 32),
                groupName: "Maple Garden",
                rules: rules
            )
        }

        func makeChat(
            introPublicKey: Data = Data(repeating: 0x44, count: 32),
            invitationMessage: String? = "come in"
        ) -> PendingChat {
            PendingChat(
                groupID: Data(repeating: 0x11, count: 32),
                ownerIdentityID: owner ?? IdentityID(),
                introPublicKey: introPublicKey,
                groupName: "Maple Garden",
                inviterAlias: "Alice",
                invitationMessage: invitationMessage,
                receivedAt: Date(),
                status: .offered
            )
        }

        func makeGroup(id: String) -> ChatGroup {
            ChatGroup(
                id: id,
                ownerIdentityID: owner ?? IdentityID(),
                name: "Maple Garden",
                groupSecret: Data(repeating: 0x33, count: 32),
                createdAt: Date(),
                members: [],
                memberProfiles: [:],
                epoch: 0,
                salt: Data(repeating: 0x44, count: 32),
                commitment: nil,
                tier: .small,
                groupType: .tyranny,
                adminPubkeyHex: nil,
                adminEd25519PubkeyHex: nil,
                isPublishedOnChain: false
            )
        }
    }

    private func makeVerification(
        groupIDHex: String,
        owner: IdentityID,
        status: PendingGroupVerification.Status
    ) -> PendingGroupVerification {
        PendingGroupVerification(
            groupIDHex: groupIDHex,
            ownerIdentityID: owner,
            groupName: "Maple Garden",
            status: status,
            receivedAt: Date()
        )
    }

    // MARK: - Waiting

    private func waitFor(
        timeout: TimeInterval = 2,
        interval: TimeInterval = 0.02,
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        XCTFail("Timed out waiting for predicate", file: file, line: line)
    }

    private func waitForAsync(
        timeout: TimeInterval = 2,
        interval: TimeInterval = 0.02,
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        XCTFail("Timed out waiting for predicate", file: file, line: line)
    }
}

// MARK: - Stubs

/// Stands in for `JoinRequestSender`, with a gate so a test can hold a
/// send open and observe the in-flight state.
private actor SpyJoinSender {
    struct Call: Sendable {
        let capability: IntroCapability
        let label: String
        /// The rules text the send signed, so a test can assert that a
        /// request agreed to what the screen displayed.
        let rules: String?
    }

    private(set) var calls: [Call] = []
    private var outcome: JoinRequestSender.Outcome = .sent
    private var gate: CheckedContinuation<Void, Never>?
    private var held = false

    func setOutcome(_ outcome: JoinRequestSender.Outcome) { self.outcome = outcome }

    func hold() { held = true }

    func release() {
        held = false
        gate?.resume()
        gate = nil
    }

    func send(
        capability: IntroCapability,
        label: String,
        rules: String?
    ) async -> JoinRequestSender.Outcome {
        calls.append(Call(capability: capability, label: label, rules: rules))
        if held {
            await withCheckedContinuation { continuation in
                if held { gate = continuation } else { continuation.resume() }
            }
        }
        return outcome
    }
}

private actor Recorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
