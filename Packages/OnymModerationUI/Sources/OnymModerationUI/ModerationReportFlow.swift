import Foundation
import OnymModeration

@MainActor
@Observable
public final class ModerationReportFlow {
    public struct State: Equatable {
        public var classes: [ViolationClass] = []
        public var selectedClassId: String?
        public var isLoading = false
        public var isSubmitting = false
        public var receipt: ReportReceipt?
        /// Terminal like `receipt`: the Authority confirmed it already
        /// holds this exact report (409), but no receipt exists to show.
        public var alreadyFiled = false
        public var errorMessage: String?
    }

    public private(set) var state = State()
    public let message: ReportableMessage

    private let repository: ModerationRepository

    public init(message: ReportableMessage, repository: ModerationRepository) {
        self.message = message
        self.repository = repository
    }

    public func start() async {
        guard state.classes.isEmpty, !state.isLoading else { return }
        state.isLoading = true
        state.errorMessage = nil
        defer { state.isLoading = false }
        // Delivery needs the authorities directory; on a cold launch
        // straight into Report it may not have been fetched yet, and
        // `fileReport` would throw `authorityUnavailable`. Best-effort —
        // a failure here surfaces at submit with directory copy.
        try? await repository.refresh()
        do {
            let classes = try await repository.availableReportClasses()
            state.classes = classes
            // Deliberately no preselection: the class is the substance
            // of the report, and the first class in a manifest is often
            // the gravest (the live manifest leads with CSAM). Filing
            // must require an explicit choice, never survive a reflex
            // double-tap.
            if classes.isEmpty {
                state.errorMessage = String(
                    localized: "Your current authority offers no reportable classes."
                )
            }
        } catch {
            state.errorMessage = String(
                localized: "Reporting requires an active mandate registered with this authority."
            )
        }
    }

    public func selectClass(_ classId: String) {
        guard state.classes.contains(where: { $0.classId == classId }) else { return }
        state.selectedClassId = classId
    }

    public func submit() async {
        guard let classId = state.selectedClassId, !state.isSubmitting else { return }
        state.isSubmitting = true
        state.errorMessage = nil
        defer { state.isSubmitting = false }
        do {
            state.receipt = try await repository.fileReport(
                message: message,
                classId: classId
            )
        } catch ModerationError.authenticityUnverified {
            state.errorMessage = String(
                localized: "This message has no valid sender proof and cannot be filed as evidence."
            )
        } catch ModerationError.reportAlreadyFiled {
            // Terminal and benign: the Authority already holds this
            // exact report. Rendered like success, not as an error —
            // a Submit retry could only 409 again.
            state.alreadyFiled = true
        } catch ModerationError.reportingUnavailable,
                ModerationError.classOutsideMandate {
            // Permanent for this message/mandate; "try again" is wrong.
            state.errorMessage = String(
                localized: "Reporting requires an active mandate registered with this authority."
            )
        } catch ModerationError.authorityUnavailable {
            state.errorMessage = String(
                localized: "Your authority isn't in the directory right now. Check your connection and try again."
            )
        } catch let AuthorityClientError.rejected(rejection) {
            // Authority-controlled text; bound it so a hostile or buggy
            // authority can't flood the sheet with an arbitrary payload.
            state.errorMessage = String(rejection.message.prefix(280))
        } catch {
            state.errorMessage = String(
                localized: "The report could not be delivered. Try again to resend the exact signed report."
            )
        }
    }
}
