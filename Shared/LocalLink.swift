import Foundation
import Network

// A second channel between the app and the keyboard for signings without an App Group:
// the app listens on the loopback interface, the keyboard (with Full Access) asks it for the
// text, settings and last command and hands back its status. It works whenever both are
// alive — the app stays alive for a short while after it goes to the background.

struct LinkPayload: Codable {
    var settings: TyperSettings
    var text: String
    var command: TyperCommand?
}

struct LinkReport: Codable {
    var status: TyperStatus
    var stats: [RunStat]
}

enum LocalLink {
    static let port: UInt16 = 47823
    static let clipType = "com.werx.autotyper.payload"

    static func encode<T: Encodable>(_ v: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return (try? e.encode(v)) ?? Data()
    }
}

/// App side.
final class LinkServer {
    private var listener: NWListener?
    private let store = Store.shared

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: LocalLink.port) else { return }
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: port) else { return }
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            self?.read(c, Data())
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.listener = nil
            default: break
            }
        }
        l.start(queue: .main)
        listener = l
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self = self else { return }
            var b = buffer
            if let d = data { b.append(d) }
            if let body = self.body(of: b) {
                self.respond(c, body)
            } else if done || error != nil || b.count > 4_000_000 {
                c.cancel()
            } else {
                self.read(c, b)
            }
        }
    }

    /// Returns the request body once the whole request has arrived.
    private func body(of b: Data) -> Data? {
        guard let sep = b.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: b[..<sep.lowerBound], as: UTF8.self)
        var length = 0
        for line in head.components(separatedBy: "\r\n") {
            let l = line.lowercased()
            if l.hasPrefix("content-length:") {
                length = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let rest = b[sep.upperBound...]
        return rest.count >= length ? Data(rest.prefix(length)) : nil
    }

    private func respond(_ c: NWConnection, _ body: Data) {
        if let report = try? JSONDecoder().decode(LinkReport.self, from: body) {
            store.status = report.status
            store.stats = report.stats
            Store.linkSeen = true
        }
        let out = LocalLink.encode(LinkPayload(settings: store.settings, text: store.text, command: store.command))
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + out, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// Keyboard side.
final class LinkClient {
    private let session: URLSession
    private var busy = false
    private var last: Data?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.5
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    /// Sends the keyboard's state; `onChange` fires when the app has something new.
    func sync(_ report: LinkReport, onChange: @escaping (LinkPayload) -> Void) {
        guard !busy, let url = URL(string: "http://127.0.0.1:\(LocalLink.port)/sync") else { return }
        busy = true
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = LocalLink.encode(report)
        session.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                guard let data = data, !data.isEmpty else { return }
                Store.linkSeen = true
                guard data != self.last, let p = try? JSONDecoder().decode(LinkPayload.self, from: data) else { return }
                self.last = data
                onChange(p)
            }
        }.resume()
    }
}
