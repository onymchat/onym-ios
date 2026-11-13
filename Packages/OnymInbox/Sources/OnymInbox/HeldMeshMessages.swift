import Foundation
import OnymChatsCore

/// Messages heard on the Bluetooth mesh that couldn't be stored yet.
///
/// The message store has Complete file protection: while the phone is
/// locked it can't be read or written, and a locked phone in a pocket is
/// exactly when a mesh message arrives. The message waits here, the
/// notification goes out anyway, and the app stores it once the phone is
/// unlocked (`IncomingMessageDispatcher.storeHeldMeshMessages`).
///
/// Memory only, by design: writing it anywhere readable while locked
/// would put a plaintext message on disk outside the protected store. If
/// the app is killed first, the broadcaster is still looping it, and the
/// relay copy catches up.
public actor HeldMeshMessages {
    private var messages: [ChatMessage] = []
    private let capacity: Int

    public init(capacity: Int = 256) {
        self.capacity = capacity
    }

    /// False when this message is already waiting — the caller has
    /// notified for it once.
    func hold(_ message: ChatMessage) -> Bool {
        guard !messages.contains(where: { $0.id == message.id && $0.ownerIdentityID == message.ownerIdentityID })
        else { return false }
        if messages.count >= capacity { messages.removeFirst() }
        messages.append(message)
        return true
    }

    func takeAll() -> [ChatMessage] {
        defer { messages = [] }
        return messages
    }

    public var count: Int { messages.count }
}
