import Foundation

enum SmokeError: Error {
    case usage, expectedEmptyDirectory, missingProgress, didNotCancel, incomplete
}

func smokeAssets() throws -> ModelAssets {
    guard CommandLine.arguments.count == 3,
          ["download", "offline"].contains(CommandLine.arguments[1]) else { throw SmokeError.usage }
    return ModelAssets(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
}

func checkInstalled(_ assets: ModelAssets) throws {
    guard assets.isInstalled else { throw SmokeError.incomplete }
    print("All verified files are present.")
}

func checkDownload(_ assets: ModelAssets) async throws {
    let contents = try? FileManager.default.contentsOfDirectory(atPath: assets.directory.path)
    guard contents?.isEmpty ?? true else { throw SmokeError.expectedEmptyDirectory }
    guard !assets.isInstalled else { throw SmokeError.expectedEmptyDirectory }

    let progress = Progress(totalUnitCount: ModelAssets.totalSize)
    let interrupted = Task {
        try await assets.install { progress.completedUnitCount = $0 }
    }
    let deadline = ContinuousClock.now + .seconds(60)
    while progress.completedUnitCount == 0 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    interrupted.cancel()
    do {
        try await interrupted.value
        throw SmokeError.didNotCancel
    } catch is CancellationError {
        // A cancellation can happen during validation after the HTTP request ends.
    } catch let error as URLError where error.code == .cancelled {
        // URLSession can report cancellation before the next Task.checkCancellation.
    }
    guard progress.completedUnitCount > 0 else { throw SmokeError.missingProgress }
    guard !assets.isInstalled else { throw SmokeError.didNotCancel }
    print("Canceled an active download without marking the model ready.")

    try await assets.install { progress.completedUnitCount = $0 }
    guard progress.completedUnitCount == ModelAssets.totalSize else { throw SmokeError.incomplete }
    print("Retried and verified all \(ModelAssets.totalSize) bytes.")
}
