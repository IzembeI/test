import SwiftUI
import AVFoundation
import PhotosUI

struct QRScannerView: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreview(onCode: onCode).ignoresSafeArea()
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 250, height: 250)
                VStack {
                    Spacer()
                    if let m = message { Text(m).padding(8).background(.ultraThinMaterial, in: Capsule()) }
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Выбрать из фото", systemImage: "photo")
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Сканер QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .onChange(of: photo) { item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let img = CIImage(data: data) else { message = "Не удалось открыть фото"; return }
                    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
                    let codes = detector?.features(in: img).compactMap { ($0 as? CIQRCodeFeature)?.messageString } ?? []
                    if let c = codes.first { onCode(c) } else { message = "На фото нет QR-кода" }
                }
            }
        }
    }
}

struct CameraPreview: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async { ok ? self.setup() : self.denied() }
        }
    }

    private func denied() {
        let l = UILabel()
        l.text = "Нет доступа к камере.\nРазрешите его в Настройках или выберите фото."
        l.numberOfLines = 0
        l.textAlignment = .center
        l.textColor = .white
        l.frame = view.bounds.insetBy(dx: 24, dy: 0)
        l.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(l)
    }

    private func setup() {
        guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else { denied(); return }
        session.addInput(input)
        let out = AVCaptureMetadataOutput()
        guard session.canAddOutput(out) else { return }
        session.addOutput(out)
        out.setMetadataObjectsDelegate(self, queue: .main)
        out.metadataObjectTypes = [.qr]
        let p = AVCaptureVideoPreviewLayer(session: session)
        p.videoGravity = .resizeAspectFill
        p.frame = view.bounds
        view.layer.addSublayer(p)
        preview = p
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        done = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        session.stopRunning()
        onCode?(code)
    }
}
