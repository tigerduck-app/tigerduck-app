import Foundation

nonisolated enum MoodleFileTransfer {
    static func downloadURL(
        for fileURL: URL,
        accessKey: String?,
        token: String,
        siteURL: URL = AppConstants.moodleBaseURL
    ) -> URL? {
        guard fileURL.scheme?.lowercased() == "https",
              let host = fileURL.host?.lowercased(), host == siteURL.host?.lowercased(),
              var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath
        guard let script = ["/webservice/pluginfile.php/", "/pluginfile.php/"].first(where: { path.hasPrefix($0) }) else {
            return nil
        }
        let rest = path.dropFirst(script.count)
        var items = (components.queryItems ?? []).filter { $0.name != "token" }
        if let key = accessKey?.addingPercentEncoding(withAllowedCharacters: .alphanumerics), !key.isEmpty {
            components.percentEncodedPath = "/tokenpluginfile.php/\(key)/\(rest)"
        } else {
            components.percentEncodedPath = "/webservice/pluginfile.php/\(rest)"
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    static func fetch(
        _ url: URL,
        mimeType: String?,
        expectedSize: Int,
        session: URLSession = MoodleWebserviceClient.session,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let (location, response) = try await download(url, expectedSize: expectedSize, session: session, progress: progress)
        do {
            try check(response, at: location, mimeType: mimeType)
            return location
        } catch {
            try? FileManager.default.removeItem(at: location)
            throw error
        }
    }

    static func check(_ response: URLResponse, at location: URL, mimeType: String?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MoodleWebserviceError.malformedResponse(detail: "No HTTP response")
        }
        let served = baseType(http.value(forHTTPHeaderField: "Content-Type"))
        let expected = baseType(mimeType)
        if served == "application/json", let error = moodleError(at: location) { throw error }
        guard http.statusCode == 200 else { throw MoodleWebserviceError.httpStatus(code: http.statusCode) }
    /// Moodle sends a stored file with the MIME type it lists for it, so another type is a page
    /// standing in for the file. A file it lists as `document/unknown` comes as
    /// `application/octet-stream`, and one it lists with no type as any type, so any type but a page
    /// passes for either. A web service error comes as JSON and throws its own case, even for a JSON
    /// file, whose own type the error shares.
        let listed = expected.flatMap { $0.isEmpty || $0 == "document/unknown" ? nil : $0 }
        let isFile = listed.map { served == $0 } ?? (served != "text/html")
        if !isFile { throw MoodleWebserviceError.malformedResponse(detail: served ?? "") }
    }

    private static let errorReplyLimit = 64 * 1024

    private static func moodleError(at location: URL) -> MoodleWebserviceError? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? Int,
              size <= errorReplyLimit, let data = try? Data(contentsOf: location) else { return nil }
        return MoodleWebserviceError.from(jsonData: data)
    }

    private static func baseType(_ raw: String?) -> String? {
        raw?.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func download(
        _ url: URL,
        expectedSize: Int,
        session: URLSession,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let running = RunningTransfer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url) { location, response, error in
                    running.finish()
                    if let error {
                        continuation.resume(throwing: Self.mapped(error))
                        return
                    }
                    guard let location, let response else {
                        continuation.resume(throwing: MoodleWebserviceError.malformedResponse(detail: "No file"))
                        return
                    }
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent("MoodleDownload-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: (kept, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let observation = task.progress.observe(\.completedUnitCount) { transfer, _ in
                    // The system deletes `location` once this handler returns.
                    let total = transfer.totalUnitCount > 0 ? transfer.totalUnitCount : Int64(expectedSize)
                    progress(total > 0 ? min(1, Double(transfer.completedUnitCount) / Double(total)) : 0)
                }
                running.start(task, observation)
            }
        } onCancel: {
            running.cancel()
        }
    }

    private static func mapped(_ error: any Error) -> any Error {
        guard let urlError = error as? URLError else { return error }
        if urlError.code == .cancelled { return CancellationError() }
        return MoodleWebserviceError.transientNetwork(underlying: urlError.localizedDescription)
    }
}

private nonisolated final class RunningTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var isCancelled = false

    func start(_ task: URLSessionDownloadTask, _ observation: NSKeyValueObservation) {
        let cancelled = lock.withLock {
            self.task = task
            self.observation = observation
            return isCancelled
        }
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    func finish() {
        let observation = lock.withLock {
            defer { self.observation = nil }
            return self.observation
        }
        observation?.invalidate()
    }
}
