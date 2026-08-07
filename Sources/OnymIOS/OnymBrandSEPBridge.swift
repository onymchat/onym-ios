import OnymDesign

// MARK: - OnymUIGovernance ↔ SEPGroupType bridge

/// Maps the design package's UI-side governance mirror onto the Chain
/// domain type. Lives in the app target so `OnymDesign` stays a
/// dependency-free leaf package with no knowledge of Chain types.
extension OnymUIGovernance {
    var sepGroupType: SEPGroupType {
        switch self {
        case .tyranny: .tyranny
        case .oneOnOne: .oneOnOne
        case .anarchy: .anarchy
        }
    }
}
