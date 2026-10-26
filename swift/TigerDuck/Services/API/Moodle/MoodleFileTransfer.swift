import Foundation

nonisolated enum MoodleFileTransfer {
    /// A GET under `tokenpluginfile.php` with the private access key, as the Moodle app downloads
    /// files, or without the key a POST to the web service path with the token in the form, which
    /// `pluginfile.php` reads as it reads the query and access logs do not keep.
    static func downloadRequest(
        for fileURL: URL,
        accessKey: String?,
        token: String,
        siteURL: URL = AppConstants.moodleBaseURL
    ) -> URLRequest? {
        guard fileURL.scheme?.lowercased() == "https",
              let host = fileURL.host?.lowercased(), host == siteURL.host?.lowercased(),
              var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath
        guard let script = ["/webservice/pluginfile.php/", "/pluginfile.php/"].first(where: { path.hasPrefix($0) }) else {
            return nil
        }
        let rest = path.dropFirst(script.count)
        let items = (components.queryItems ?? []).filter { $0.name != "token" }
        let key = accessKey?.addingPercentEncoding(withAllowedCharacters: .alphanumerics).flatMap { $0.isEmpty ? nil : $0 }
        components.percentEncodedPath = key.map { "/tokenpluginfile.php/\($0)/\(rest)" } ?? "/webservice/pluginfile.php/\(rest)"
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        if key == nil {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(MoodleWebserviceClient.formBody([("token", token)]).utf8)
        }
        return request
    }

    /// A POST carries the token, so its redirects go through `CredentialPostDelegate`.
    static func redirectGuard(for request: URLRequest) -> CredentialPostDelegate? {
        request.httpMethod == "POST" ? CredentialPostDelegate() : nil
    }

    static func fetch(
        _ request: URLRequest,
        mimeType: String?,
        expectedSize: Int,
        session: URLSession = MoodleWebserviceClient.session,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let (location, response) = try await download(request, expectedSize: expectedSize, session: session, progress: progress)
        do {
            try check(response, at: location, mimeType: mimeType)
            return location
        } catch {
            try? FileManager.default.removeItem(at: location)
            throw error
        }
    }

    /// Moodle sends a stored file with the MIME type it lists for it, so another type is a page
    /// standing in for the file. A file it lists as `document/unknown` comes as
    /// `application/octet-stream`, and one it lists with no type as any type, so any type but a page
    /// passes for either. A web service error comes as JSON and throws its own case, even for a JSON
    /// file, whose own type the error shares.
    static func check(_ response: URLResponse, at location: URL, mimeType: String?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MoodleWebserviceError.malformedResponse(detail: "No HTTP response")
        }
        let served = baseType(http.value(forHTTPHeaderField: "Content-Type"))
        let expected = baseType(mimeType)
        if served == "application/json", let error = moodleError(at: location) { throw error }
        guard http.statusCode == 200 else { throw MoodleWebserviceError.httpStatus(code: http.statusCode) }
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
        _ request: URLRequest,
        expectedSize: Int,
        session: URLSession,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let running = RunningTransfer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { location, response, error in
                    running.finish()
                    if let error {
                        continuation.resume(throwing: Self.mapped(error))
                        return
                    }
                    guard let location, let response else {
                        continuation.resume(throwing: MoodleWebserviceError.malformedResponse(detail: "No file"))
                        return
                    }
                    // The system deletes `location` once this handler returns.
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent("MoodleDownload-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: (kept, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                task.delegate = redirectGuard(for: request)
                let observation = task.progress.observe(\.completedUnitCount) { transfer, _ in
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
