import AVFoundation
import SwiftUI

/// Sheet-presented camera surface that scans QR codes and reports the
/// decoded payload via `onScanned`. Wraps an `AVCaptureSession` with a
/// `AVCaptureMetadataOutput` filtered to QR codes.
///
/// The scanner is intentionally generic — it doesn't know what the
/// payload means. Callers (today, `CreateGroupInviteByKeyView`) parse
/// the scanned string into an inbox key via
/// `CreateGroupFlow.canonicalizeInviteKey(_:)`. Keeping the parser out
/// of the scanner lets the same view scan future payload shapes
/// without round-tripping through the camera surface.
struct QRCodeScannerView: View {
    let onScanned: (String) -> Void
    let onCancel: () -> Void

    @State private var failure: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let failure {
                VStack(spacing: 14) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(failure)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .accessibilityIdentifier("qr_scanner.error")
            } else {
                QRScannerRepresentable(
                    onScanned: onScanned,
                    onError: { failure = $0 }
                )
                .ignoresSafeArea()
                .accessibilityIdentifier("qr_scanner.preview")

                viewfinder
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                            .font(.system(size: 32))
                            .padding(20)
                    }
                    .accessibilityIdentifier("qr_scanner.cancel_button")
                    .accessibilityLabel(Text("Cancel"))
                }
                Spacer()
                Text("Point your camera at an Onym invite QR code.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
            }
        }
    }

    private var viewfinder: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.65
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
                    .frame(width: side, height: side)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScanned: onScanned)
    }

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.metadataDelegate = context.coordinator
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ vc: QRScannerViewController, context: Context) {}

    /// Owns the dedup latch — without it, AVFoundation can fire the
    /// callback for the same QR several times per second, double-
    /// invoking `onScanned`.
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScanned: (String) -> Void
        private var consumed = false

        init(onScanned: @escaping (String) -> Void) {
            self.onScanned = onScanned
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !consumed else { return }
            for object in metadataObjects {
                if let m = object as? AVMetadataMachineReadableCodeObject,
                   m.type == .qr,
                   let value = m.stringValue,
                   !value.isEmpty {
                    consumed = true
                    onScanned(value)
                    return
                }
            }
        }
    }
}

private final class QRScannerViewController: UIViewController {
    weak var metadataDelegate: QRScannerRepresentable.Coordinator?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "chat.onym.qrscanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await self.ensureAuthorizedAndStart() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func ensureAuthorizedAndStart() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let granted: Bool
        switch status {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            granted = false
        }
        if granted {
            await MainActor.run { self.configureAndStart() }
        } else {
            await MainActor.run {
                self.onError?(
                    "Camera access is off. Enable it in Settings → Onym → Camera, then come back."
                )
            }
        }
    }

    private func configureAndStart() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            onError?("No camera available on this device.")
            return
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            onError?("Couldn't open the camera: \(error.localizedDescription)")
            return
        }

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            onError?("Couldn't attach the camera input.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            onError?("Couldn't attach the QR decoder.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(metadataDelegate, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }
}
