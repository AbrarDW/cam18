@preconcurrency import AVFoundation
import Foundation

/// The camera lenses Cam18 offers, when the device has them.
enum Lens: String, CaseIterable, Identifiable, Sendable {
    case ultraWide, wide, telephoto, front

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ultraWide: "0.5×"
        case .wide: "1×"
        case .telephoto: "Tele"
        case .front: "Front"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: .builtInUltraWideCamera
        case .wide, .front: .builtInWideAngleCamera
        case .telephoto: .builtInTelephotoCamera
        }
    }

    var position: AVCaptureDevice.Position { self == .front ? .front : .back }

    var device: AVCaptureDevice? {
        AVCaptureDevice.default(deviceType, for: .video, position: position)
    }
}

/// Owns the AVCaptureSession: setup, lens switching, permissions and running
/// state. All session work happens on a private serial queue.
final class CameraSession: NSObject, @unchecked Sendable {
    enum CameraError: LocalizedError {
        case notAuthorized
        case noCamera
        case configurationFailed

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Cam18 needs camera access. You can allow it in Settings."
            case .noCamera: "No camera is available on this device."
            case .configurationFailed: "The camera couldn't be set up."
            }
        }
    }

    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()
    let videoOutput = AVCaptureVideoDataOutput()
    let videoQueue = DispatchQueue(label: "cam18.video", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "cam18.session")
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var processedDimensions: CMVideoDimensions?
    private var rawDimensions: CMVideoDimensions?
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private let inFlightLock = NSLock()

    static var availableLenses: [Lens] {
        Lens.allCases.filter { $0.device != nil }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Configures inputs and outputs. `delegate` receives preview frames.
    func configure(lens: Lens, delegate: AVCaptureVideoDataOutputSampleBufferDelegate) async throws {
        let boxed = UncheckedSendable(delegate)
        try await perform { [self] in
            guard !isConfigured else { return }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .photo

            guard let device = lens.device ?? Lens.wide.device else { throw CameraError.noCamera }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.configurationFailed }
            session.addInput(input)
            currentInput = input

            guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed }
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(boxed.value, queue: videoQueue)
            guard session.canAddOutput(videoOutput) else { throw CameraError.configurationFailed }
            session.addOutput(videoOutput)

            configureConnections(for: device)
            isConfigured = true
        }
    }

    func start() {
        sessionQueue.async { [self] in
            if isConfigured, !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func switchLens(to lens: Lens) async throws {
        try await perform { [self] in
            guard let device = lens.device else { throw CameraError.noCamera }
            let newInput = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            if let currentInput { session.removeInput(currentInput) }
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                currentInput = newInput
            } else if let currentInput {
                session.addInput(currentInput)
                throw CameraError.configurationFailed
            }
            configureConnections(for: device)
        }
    }

    /// Must run inside a configuration block on the session queue.
    private func configureConnections(for device: AVCaptureDevice) {
        // Processed photos use the largest size up to ~24 MP: full quality
        // without the slow 48 MP path. RAW uses the sensor's largest size,
        // because it has no multi-frame merging to recover distant detail.
        func area(_ d: CMVideoDimensions) -> Int64 { Int64(d.width) * Int64(d.height) }
        let all = device.activeFormat.supportedMaxPhotoDimensions
        let largest = all.max { area($0) < area($1) }
        processedDimensions = all.filter { area($0) <= 25_000_000 }.max { area($0) < area($1) } ?? largest
        rawDimensions = largest
        if let largest { photoOutput.maxPhotoDimensions = largest }

        if let connection = videoOutput.connection(with: .video) {
            // The UI is portrait-only, so preview frames are delivered portrait.
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = device.position == .front
            }
        }
    }

    /// The Bayer RAW format the current lens offers, if any. Bayer RAW is the
    /// sensor data itself; Apple ProRAW is deliberately not used, because it
    /// is already processed.
    private var bayerRAWFormat: OSType? {
        photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
    }

    /// Whether the current lens can capture RAW.
    func supportsRAW() async -> Bool {
        await withCheckedContinuation { cont in
            sessionQueue.async { [self] in cont.resume(returning: isConfigured && bayerRAWFormat != nil) }
        }
    }

    /// Captures a photo and returns its encoded data, including the camera's
    /// EXIF: a RAW DNG when `raw` is true and the lens supports it, otherwise
    /// the camera's processed HEIC/JPEG. `rotationAngle` comes from the
    /// device's orientation.
    func capturePhoto(rotationAngle: CGFloat, raw: Bool) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            sessionQueue.async { [self] in
                if let connection = photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                let settings: AVCapturePhotoSettings
                if raw, let format = bayerRAWFormat {
                    // RAW only: no processed companion image is produced.
                    settings = AVCapturePhotoSettings(rawPixelFormatType: format)
                    // Bayer RAW has no multi-frame processing to prioritise, and
                    // AVFoundation raises an exception for any other value.
                    settings.photoQualityPrioritization = .speed
                    if let rawDimensions { settings.maxPhotoDimensions = rawDimensions }
                } else {
                    if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                        settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                    } else {
                        settings = AVCapturePhotoSettings()
                    }
                    settings.maxPhotoDimensions = processedDimensions ?? photoOutput.maxPhotoDimensions
                    settings.photoQualityPrioritization = .balanced
                }
                let id = settings.uniqueID
                let processor = PhotoCaptureProcessor { [weak self] result in
                    self?.removeInFlight(id)
                    cont.resume(with: result)
                }
                inFlightLock.lock(); inFlight[id] = processor; inFlightLock.unlock()
                photoOutput.capturePhoto(with: settings, delegate: processor)
            }
        }
    }

    private func removeInFlight(_ id: Int64) {
        inFlightLock.lock(); inFlight[id] = nil; inFlightLock.unlock()
    }

    private func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do { try work(); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
    }
}
