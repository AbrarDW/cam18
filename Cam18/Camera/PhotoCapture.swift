@preconcurrency import AVFoundation
import Foundation

/// Receives the callbacks for one photo capture and reports the encoded data
/// (with the camera's EXIF) once the capture finishes.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noData
        var errorDescription: String? { "The camera didn't return a photo." }
    }

    private let completion: @Sendable (Result<Data, Error>) -> Void
    private var data: Data?
    private var error: Error?
    private let lock = NSLock()

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if let error {
            self.error = error
        } else {
            data = photo.fileDataRepresentation()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        let result: Result<Data, Error>
        if let error = error ?? self.error {
            result = .failure(error)
        } else if let data {
            result = .success(data)
        } else {
            result = .failure(CaptureError.noData)
        }
        lock.unlock()
        completion(result)
    }
}
