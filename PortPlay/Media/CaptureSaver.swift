import Foundation

#if os(iOS)
import Photos
import UIKit
#else
import AppKit
#endif

/// Where screenshots and clips end up. On Mac that's a PortPlay folder in
/// Pictures or Movies, like the Windows app. On iPad it's the Photos library.
enum CaptureSaver {
    enum Kind {
        case screenshot
        case video
    }

    struct Saved {
        /// The file on Mac, for "Show in Finder". Nil on iPad.
        let file: URL?
        /// Where it went, for the toast.
        let place: String
    }

    enum SaveError: LocalizedError {
        case photosDenied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .photosDenied: return "PortPlay isn't allowed to add to Photos. You can turn it on in Settings."
            case .failed(let reason): return reason
            }
        }
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    /// A scratch file for a recording or replay before it's saved.
    static func temporaryVideoURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("portplay-\(UUID().uuidString).mp4")
    }

    // MARK: Screenshots

    static func saveScreenshot(_ png: Data, completion: @escaping (Result<Saved, Error>) -> Void) {
        #if os(iOS)
        addToPhotos(completion: completion) { request in
            request.addResource(with: .photo, data: png, options: nil)
        }
        #else
        do {
            let url = try uniqueURL(kind: .screenshot, ext: "png")
            try png.write(to: url)
            completion(.success(Saved(file: url, place: "Pictures")))
        } catch {
            completion(.failure(error))
        }
        #endif
    }

    // MARK: Clips

    /// Moves a finished recording or replay from its scratch file to its final home.
    static func saveVideo(at temporary: URL, completion: @escaping (Result<Saved, Error>) -> Void) {
        #if os(iOS)
        addToPhotos(completion: { result in
            try? FileManager.default.removeItem(at: temporary)
            completion(result)
        }) { request in
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: .video, fileURL: temporary, options: options)
        }
        #else
        do {
            let url = try uniqueURL(kind: .video, ext: "mp4")
            try FileManager.default.moveItem(at: temporary, to: url)
            completion(.success(Saved(file: url, place: "Movies")))
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            completion(.failure(error))
        }
        #endif
    }

    // MARK: Clipboard

    @discardableResult
    static func copyImage(_ png: Data) -> Bool {
        #if os(iOS)
        guard let image = UIImage(data: png) else { return false }
        UIPasteboard.general.image = image
        return true
        #else
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(png, forType: .png)
        #endif
    }

    // MARK: Platform details

    #if os(iOS)
    private static func addToPhotos(
        completion: @escaping (Result<Saved, Error>) -> Void,
        changes: @escaping (PHAssetCreationRequest) -> Void
    ) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(SaveError.photosDenied)) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                changes(PHAssetCreationRequest.forAsset())
            }) { ok, error in
                DispatchQueue.main.async {
                    if ok {
                        completion(.success(Saved(file: nil, place: "Photos")))
                    } else {
                        completion(.failure(error ?? SaveError.failed("Photos didn't accept the file.")))
                    }
                }
            }
        }
    }

    static func openPhotos() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }
    #else
    /// The real home folder. Inside the sandbox, FileManager points at the app's container instead.
    private static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func uniqueURL(kind: Kind, ext: String) throws -> URL {
        let parent = kind == .screenshot ? "Pictures" : "Movies"
        let prefix = kind == .screenshot ? "Screenshot" : "Clip"
        let folder = realHome.appendingPathComponent(parent).appendingPathComponent("PortPlay", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let stamp = timestamp()
        var url = folder.appendingPathComponent("\(prefix) \(stamp).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(prefix) \(stamp) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif
}
