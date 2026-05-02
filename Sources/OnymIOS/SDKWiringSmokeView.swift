import OnymSDK
import SwiftUI

/// First-chunk scaffold: verify OnymSDK is wired in by calling one
/// FFI function and rendering the result. No app architecture yet
/// (repos / unidirectional flow lands when there's actual domain
/// logic to model).
///
/// `pinnedMembershipVKSha256Hex(depth: 5)` is the cheapest call that
/// proves the full chain works — SwiftPM resolves the binaryTarget,
/// the XCFramework's libOnymFFI.a is on the linker line, the C ABI
/// is reachable, and the underlying Rust returns the static SHA-256
/// hex constant for the depth-5 anarchy membership VK.
struct SDKWiringSmokeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("OnymSDK wired", systemImage: "checkmark.seal.fill")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("SDK version").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(OnymSDK.version).font(.body.monospaced())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Anarchy depth-5 membership VK SHA-256 (pinned)")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(pinnedHexResult)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pinnedHexResult: String {
        do {
            return try Anarchy.pinnedMembershipVKSha256Hex(depth: 5)
        } catch let error as OnymError {
            return "OnymError: \(error.message)"
        } catch {
            return "Unexpected error: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SDKWiringSmokeView()
}
