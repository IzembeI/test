import Foundation

enum GeoDownloader {
    /// Downloads to a temporary file first, so a broken download never
    /// replaces a working database.
    static func download(_ url: URL, to dest: URL, timeout: TimeInterval = 120, _ done: @escaping (Bool) -> Void) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)
        let task = session.downloadTask(with: url) { tmp, resp, _ in
            defer { session.finishTasksAndInvalidate() }
            guard let tmp, let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int, size > 1024 else {
                done(false); return
            }
            let fm = FileManager.default
            try? fm.removeItem(at: dest)
            do {
                try fm.moveItem(at: tmp, to: dest)
                done(true)
            } catch {
                done(false)
            }
        }
        task.resume()
    }
}
