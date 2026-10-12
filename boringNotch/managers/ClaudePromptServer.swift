//
//  ClaudePromptServer.swift
//  boringNotch
//
//  A loopback HTTP endpoint for Claude Code's http hooks. Each hook call stays open until the notch
//  answers it or Claude Code gives up, which it does as soon as the prompt is answered elsewhere.
//

import Foundation
import Network

struct ClaudeHookCall: Sendable {
    enum Kind: Sendable {
        case permission, question
    }

    let id: UUID
    let kind: Kind
    let body: Data
}

final class ClaudePromptServer: @unchecked Sendable {
    static let port: UInt16 = 47823

    /// Called on the server queue for every authenticated hook call.
    var onCall: (@Sendable (ClaudeHookCall) -> Void)?
    /// Called on the server queue when Claude Code closes a call that was not answered yet.
    var onAbandon: (@Sendable (UUID) -> Void)?
    /// Called on the server queue with nil once listening, or a message when the port cannot be used.
    var onStateChange: (@Sendable (String?) -> Void)?

    private let token: String
    private let queue = DispatchQueue(label: "com.twan.twanotch.claude-prompts")
    private var listener: NWListener?
    private var open: [UUID: NWConnection] = [:]

    private static let maxRequestSize = 1 << 20

    init(token: String) {
        self.token = token
    }

    func start() {
        queue.async { [self] in
            guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            parameters.allowLocalEndpointReuse = true
            do {
                let listener = try NWListener(using: parameters)
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.onStateChange?(nil)
                    case .failed(let error):
                        self?.onStateChange?(error.localizedDescription)
                        self?.stop()
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                onStateChange?(error.localizedDescription)
            }
        }
    }

    /// Stops listening and lets every waiting call fall back to Claude Code's own prompt.
    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for id in Array(open.keys) {
                send(id, status: "200 OK", body: Data())
            }
        }
    }

    /// Answers a call; an empty body leaves the decision to Claude Code's own prompt.
    func respond(_ id: UUID, body: Data) {
        queue.async { [self] in
            send(id, status: "200 OK", body: body)
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest(parsing: buffer) {
                self.handle(request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else if buffer.count > Self.maxRequestSize {
                self.reply(on: connection, status: "413 Payload Too Large", body: Data())
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        let kind: ClaudeHookCall.Kind
        switch request.path {
        case "/twanotch/permission": kind = .permission
        case "/twanotch/question": kind = .question
        default:
            reply(on: connection, status: "404 Not Found", body: Data())
            return
        }
        guard request.method == "POST", !token.isEmpty, request.headers["x-twanotch-token"] == token else {
            reply(on: connection, status: "403 Forbidden", body: Data())
            return
        }

        let id = UUID()
        open[id] = connection
        watchForClose(id, connection)
        onCall?(ClaudeHookCall(id: id, kind: kind, body: request.body))
    }

    /// Claude Code drops the request when the prompt is answered in the terminal or the app first.
    private func watchForClose(_ id: UUID, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.abandon(id)
            } else {
                self.watchForClose(id, connection)
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.abandon(id)
            default:
                break
            }
        }
    }

    private func abandon(_ id: UUID) {
        guard let connection = open.removeValue(forKey: id) else { return }
        connection.cancel()
        onAbandon?(id)
    }

    private func send(_ id: UUID, status: String, body: Data) {
        guard let connection = open.removeValue(forKey: id) else { return }
        reply(on: connection, status: status, body: body)
    }

    private func reply(on connection: NWConnection, status: String, body: Data) {
        var response = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                .utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Just enough HTTP/1.1 to read one POST with a Content-Length body.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns nil until the whole request has arrived.
    init?(parsing buffer: Data) {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= length else { return nil }

        method = String(requestLine[0])
        path = String(requestLine[1].split(separator: "?").first ?? "")
        self.headers = headers
        self.body = Data(body.prefix(length))
    }
}
