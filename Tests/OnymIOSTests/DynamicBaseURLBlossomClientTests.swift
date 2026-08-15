import XCTest
@testable import OnymIOS
import OnymTransportBlossom

/// `DynamicBaseURLBlossomClient` resolves its base URL per operation —
/// the seam that makes a Blossom server change in Settings (or an
/// onboarding pick) apply to the very next upload/download instead of
/// the next launch. Tests use a recording inner client so the resolved
/// URL each operation was built against is observable.
final class DynamicBaseURLBlossomClientTests: XCTestCase {
    private let serverA = URL(string: "https://a.blossom.example")!
    private let serverB = URL(string: "https://b.blossom.example")!

    func test_upload_resolvesBaseURLAndForwards() async throws {
        let recorder = Recorder()
        let client = DynamicBaseURLBlossomClient(
            resolveBaseURL: { [serverA] in serverA },
            makeClient: { recorder.make(baseURL: $0) }
        )

        let descriptor = try await client.upload(Data([1, 2, 3]), mimeType: "image/jpeg")

        XCTAssertEqual(recorder.operations, [.upload(baseURL: serverA, byteCount: 3, mimeType: "image/jpeg")])
        XCTAssertEqual(descriptor, Recorder.cannedDescriptor)
    }

    func test_download_resolvesBaseURLAndForwards() async throws {
        let recorder = Recorder()
        let client = DynamicBaseURLBlossomClient(
            resolveBaseURL: { [serverA] in serverA },
            makeClient: { recorder.make(baseURL: $0) }
        )

        let data = try await client.download(sha256: "cafe")

        XCTAssertEqual(recorder.operations, [.download(baseURL: serverA, sha256: "cafe")])
        XCTAssertEqual(data, Recorder.cannedBlob)
    }

    func test_baseURLChangeBetweenOperations_takesEffectImmediately() async throws {
        // The whole point of the seam: swap the resolved URL between
        // two operations and the second one targets the new server —
        // no client reconstruction, no relaunch.
        let recorder = Recorder()
        let current = CurrentURL(serverA)
        let client = DynamicBaseURLBlossomClient(
            resolveBaseURL: { current.value },
            makeClient: { recorder.make(baseURL: $0) }
        )

        _ = try await client.upload(Data([9]), mimeType: "image/jpeg")
        current.set(serverB)
        _ = try await client.download(sha256: "beef")

        XCTAssertEqual(recorder.operations, [
            .upload(baseURL: serverA, byteCount: 1, mimeType: "image/jpeg"),
            .download(baseURL: serverB, sha256: "beef"),
        ])
    }

    func test_errorsFromInnerClientPropagate() async {
        let recorder = Recorder(failWith: BlossomError.badStatus(503))
        let client = DynamicBaseURLBlossomClient(
            resolveBaseURL: { [serverA] in serverA },
            makeClient: { recorder.make(baseURL: $0) }
        )

        do {
            _ = try await client.upload(Data(), mimeType: "image/jpeg")
            XCTFail("expected the inner client's error to propagate")
        } catch let error as BlossomError {
            XCTAssertEqual(error, .badStatus(503))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_boundToServer_pinsAllOperationsToThatURL_ignoringResolver() async throws {
        // `bound(toServer:)` is the per-send pin: even though the
        // resolver now points at B, the bound client keeps operating
        // against A — the URL a message's attachments were stamped with.
        let recorder = Recorder()
        let current = CurrentURL(serverA)
        let client = DynamicBaseURLBlossomClient(
            resolveBaseURL: { current.value },
            makeClient: { recorder.make(baseURL: $0) }
        )

        let pinned = client.bound(toServer: serverA.absoluteString)
        current.set(serverB)
        _ = try await pinned.upload(Data([7]), mimeType: "image/jpeg")
        _ = try await pinned.download(sha256: "feed")

        XCTAssertEqual(recorder.operations, [
            .upload(baseURL: serverA, byteCount: 1, mimeType: "image/jpeg"),
            .download(baseURL: serverA, sha256: "feed"),
        ])
    }

    func test_boundToServer_unparseableURL_fallsBackToLiveResolution() async throws {
        let recorder = Recorder()
        let client = DynamicBaseURLBlossomClient(
            resolveBaseURL: { [serverB] in serverB },
            makeClient: { recorder.make(baseURL: $0) }
        )

        let fallback = client.bound(toServer: "")
        _ = try await fallback.download(sha256: "aa")

        XCTAssertEqual(recorder.operations, [.download(baseURL: serverB, sha256: "aa")])
    }

    func test_boundToServer_schemelessStamp_fallsBackToLiveResolution() async throws {
        // `URL(string: "blossom.example")` parses fine as a relative
        // URL — binding to it would fail every request. It must fall
        // back to live resolution instead.
        let recorder = Recorder()
        let client = DynamicBaseURLBlossomClient(
            resolveBaseURL: { [serverB] in serverB },
            makeClient: { recorder.make(baseURL: $0) }
        )

        _ = try await client.bound(toServer: "blossom.example").download(sha256: "bb")
        _ = try await client.bound(toServer: "https://").download(sha256: "cc")

        XCTAssertEqual(recorder.operations, [
            .download(baseURL: serverB, sha256: "bb"),
            .download(baseURL: serverB, sha256: "cc"),
        ])
    }

    // MARK: - fakes

    /// Records every operation, tagged with the base URL the inner
    /// client was constructed with.
    private final class Recorder: @unchecked Sendable {
        enum Operation: Equatable {
            case upload(baseURL: URL, byteCount: Int, mimeType: String)
            case download(baseURL: URL, sha256: String)
        }

        static let cannedDescriptor = BlobDescriptor(
            sha256: "aa", url: "https://a.blossom.example/aa", size: 2
        )
        static let cannedBlob = Data([0xCA, 0xFE])

        private let lock = NSLock()
        private var _operations: [Operation] = []
        private let failWith: BlossomError?

        init(failWith: BlossomError? = nil) {
            self.failWith = failWith
        }

        var operations: [Operation] { lock.withLock { _operations } }

        func make(baseURL: URL) -> any BlossomClient {
            Inner(baseURL: baseURL, recorder: self)
        }

        fileprivate func record(_ operation: Operation) throws {
            lock.withLock { _operations.append(operation) }
            if let failWith { throw failWith }
        }

        private struct Inner: BlossomClient {
            let baseURL: URL
            let recorder: Recorder

            func upload(_ blob: Data, mimeType: String) async throws -> BlobDescriptor {
                try recorder.record(.upload(
                    baseURL: baseURL, byteCount: blob.count, mimeType: mimeType
                ))
                return Recorder.cannedDescriptor
            }

            func download(sha256: String) async throws -> Data {
                try recorder.record(.download(baseURL: baseURL, sha256: sha256))
                return Recorder.cannedBlob
            }
        }
    }

    /// Mutable `@Sendable`-capturable URL for the resolver closure.
    private final class CurrentURL: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: URL
        init(_ value: URL) { _value = value }
        var value: URL { lock.withLock { _value } }
        func set(_ newValue: URL) { lock.withLock { _value = newValue } }
    }
}
