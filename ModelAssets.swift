import CryptoKit
import Foundation

struct ModelAssets {
    struct Asset {
        let name: String
        let revision: String
        let path: String
        let size: Int64
        let sha256: String

        var url: URL {
            URL(string: "https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/resolve/\(revision)/languages/english/\(path)")!
        }
    }

    private static let voiceRevision = "a3055dcb533cf2ec90458008a01e7cef550bae2a"
    static let files = [
        Asset(name: "model.safetensors", revision: "a7056f505a4a8ca72d8b5fb1440071d6f1a35739",
              path: "model.safetensors", size: 219_029_196,
              sha256: "4c56cbd171c63e8a26ea61f5d48b8a0cd8f3c51f4652c0ab9a19bfcced8c931d"),
        Asset(name: "tokenizer.json", revision: "00eac05ed3d16bdc3f6b5d598874019c34a89214",
              path: "tokenizer.json", size: 245_020,
              sha256: "f498428e1eafee50492f7be13dc9bfafcfc12e508cd0eb1b01c92ecd5d8c6687"),
        preset("alba", size: 6_244_152, sha256: "4206b7194018c7e345e5cfd99f147caad36285df858ea153d0188c40d9f261e5"),
        preset("anna", size: 7_620_408, sha256: "4f1a928fc92ae04367324cc5d880745c1e6680bd56bf99e5d26a1e80c2cff421"),
        preset("marius", size: 6_244_152, sha256: "6fd2496993221be51edc027820fa465b67221d7e369b8caeab40076040d561dd"),
        preset("george", size: 5_900_088, sha256: "fc5ff4439cbbb532b69d2762524b55844e03352102f13376f2fa00443bc04090"),
        preset("vera", size: 6_686_520, sha256: "6deb7eb7606810edbba1c9639376d6750a8f441e464e279c43341debf5c29765"),
    ]
    static let totalSize = files.reduce(0) { $0 + $1.size }

    let directory: URL

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Pocket Speak/English Model v4")) {
        self.directory = directory
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: location("verified").path)
            && Self.files.allSatisfy { fileSize(location($0.name)) == $0.size }
    }

    func location(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func install(progress: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = location("verified")
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
        var completed: Int64 = 0
        for asset in Self.files {
            try Task.checkCancellation()
            let destination = location(asset.name)
            if try !matches(destination, asset) {
                let base = completed
                let delegate = DownloadProgress { progress(base + min($0, asset.size)) }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 30 * 60
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                let (download, response) = try await session.download(from: asset.url)
                defer { try? FileManager.default.removeItem(at: download) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw DownloadError.server(asset.name, (response as? HTTPURLResponse)?.statusCode)
                }
                guard try matches(download, asset) else { throw DownloadError.integrity(asset.name) }
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: download)
                } else {
                    try FileManager.default.moveItem(at: download, to: destination)
                }
            }
            completed += asset.size
            progress(completed)
        }
        try Task.checkCancellation()
        try Data().write(to: marker, options: .atomic)
    }

    private static func preset(_ voice: String, size: Int64, sha256: String) -> Asset {
        let file = "\(voice).safetensors"
        return Asset(name: file, revision: voiceRevision, path: "embeddings/\(file)", size: size, sha256: sha256)
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    private func matches(_ url: URL, _ asset: Asset) throws -> Bool {
        guard fileSize(url) == asset.size else { return false }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64) -> Void

    init(_ update: @escaping @Sendable (Int64) -> Void) { self.update = update }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        update(totalBytesWritten)
    }
}

private enum DownloadError: LocalizedError {
    case server(String, Int?)
    case integrity(String)

    var errorDescription: String? {
        switch self {
        case let .server(file, code): return "Couldn’t download \(file) (HTTP \(code ?? 0))."
        case let .integrity(file): return "The download for \(file) didn’t pass verification."
        }
    }
}
