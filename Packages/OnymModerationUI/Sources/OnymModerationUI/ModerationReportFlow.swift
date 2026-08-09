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
        do {
            let classes = try await repository.availableReportClasses()
            state.classes = classes
            state.selectedClassId = classes.first?.classId
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
        } catch let AuthorityClientError.rejected(rejection) {
            state.errorMessage = rejection.message
        } catch {
            state.errorMessage = String(
                localized: "The report could not be delivered. Try again to resend the exact signed report."
            )
        }
    }
}
