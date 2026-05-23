import SwiftUI
import PhotosUI
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// Tappable group-avatar slot: shows the photo-or-mark (`OnymGroupAvatar`)
/// with a camera badge, and on tap offers a gallery pick or an on-device
/// Image Playground generation. Both sources funnel through
/// `GroupAvatarImage` so whatever lands on the bound `imageData` is the
/// squared, budgeted JPEG we can seal into a NOSTR envelope.
///
/// Reused by the create flow and (later) the admin "change photo" entry
/// point — it owns no group state, just edits a `Data?` binding.
struct GroupAvatarPickerButton: View {
    @Binding var imageData: Data?
    var size: CGFloat = 92
    var accent: Color = OnymAccent.blue.color
    /// Seeds Image Playground (e.g. the group name) so the first
    /// suggestions relate to the group. Empty → no seed concept.
    var conceptText: String = ""

    @State private var showOptions = false
    @State private var photosItem: PhotosPickerItem?
    @State private var showPhotosPicker = false
    @State private var showAISheet = false

    /// On-device generation is iOS 18.1+ and only on Apple-Intelligence
    /// capable hardware. Hide the option entirely otherwise — gallery
    /// still works everywhere.
    private var aiAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, *) {
            return ImagePlaygroundViewController.isAvailable
        }
        #endif
        return false
    }

    var body: some View {
        Button { showOptions = true } label: { avatarVisual }
            .buttonStyle(.plain)
            .accessibilityIdentifier("group.avatar.edit")
            .confirmationDialog("Group photo", isPresented: $showOptions, titleVisibility: .visible) {
                Button("Choose Photo") { showPhotosPicker = true }
                if aiAvailable {
                    Button("Generate with AI") { showAISheet = true }
                }
                if imageData != nil {
                    Button("Remove Photo", role: .destructive) { imageData = nil }
                }
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $photosItem, matching: .images)
            .onChange(of: photosItem) { _, item in
                guard let item else { return }
                Task { await loadFromGallery(item) }
            }
            .modifier(
                ImagePlaygroundPresenter(
                    isPresented: $showAISheet,
                    concept: conceptText,
                    onImage: setFromURL
                )
            )
    }

    private var avatarVisual: some View {
        ZStack(alignment: .bottomTrailing) {
            OnymGroupAvatar(size: size, accent: accent, imageData: imageData)
            ZStack {
                Circle()
                    .fill(accent)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(OnymTokens.bg, lineWidth: 2))
                Image(systemName: "camera.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnymTokens.onAccent)
            }
            .offset(x: 4, y: 4)
        }
    }

    private func loadFromGallery(_ item: PhotosPickerItem) async {
        guard
            let data = try? await item.loadTransferable(type: Data.self),
            let encoded = GroupAvatarImage.encode(fromImageData: data)
        else { return }
        await MainActor.run { imageData = encoded }
    }

    private func setFromURL(_ url: URL) {
        guard
            let data = try? Data(contentsOf: url),
            let encoded = GroupAvatarImage.encode(fromImageData: data)
        else { return }
        imageData = encoded
    }
}

/// Applies `imagePlaygroundSheet` only where it exists (iOS 18.1+ with
/// the framework present); a no-op passthrough otherwise. Isolating the
/// availability fork here keeps `GroupAvatarPickerButton.body` clean.
private struct ImagePlaygroundPresenter: ViewModifier {
    @Binding var isPresented: Bool
    var concept: String
    var onImage: (URL) -> Void

    func body(content: Content) -> some View {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, *) {
            content.imagePlaygroundSheet(
                isPresented: $isPresented,
                concepts: concept.isEmpty ? [] : [.text(concept)]
            ) { url in
                onImage(url)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
