//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2023 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOHTTP1

public enum WebSocketExtension {
    case perMessageDeflate(maxWindow: Int? = 15, noContextTakeover: Bool)

    /// Initialise WebSocketExtension from header value sent to either client or server
    /// - Parameters:
    ///   - header: header value
    ///   - type: client or server
    init?(from header: String, type: HBWebSocket.SocketType) {
        var parameters = header.split(separator: ";", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }[...]
        switch parameters.first {
        case "permessage-deflate":
            var maxWindow = 15
            var noContextTakeover = false
            while let parameter = parameters.first {
                let keyValue = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let key = keyValue.first {
                    let value: String?
                    if keyValue.count > 1 {
                        value = keyValue.last
                    } else {
                        value = nil
                    }
                    switch (key, type) {
                    case ("client_max_window_bits", .server), ("server_max_window_bits", .client):
                        guard let valueString = value, let valueNumber = Int(valueString) else { return nil }
                        maxWindow = valueNumber

                    case ("client_max_window_bits", .client), ("server_max_window_bits", .server):
                        guard value == nil else { return nil }

                    case ("server_no_context_takeover", .server), ("client_no_context_takeover", .client):
                        noContextTakeover = true

                    case ("server_no_context_takeover", .client), ("client_no_context_takeover", .server):
                        break

                    default:
                        return nil
                    }
                }
                parameters = parameters.dropFirst()
            }
            guard (9...15).contains(maxWindow) else { return nil }
            self = .perMessageDeflate(maxWindow: maxWindow, noContextTakeover: noContextTakeover)
        default:
            return nil
        }
    }

    /// Negotiation response to extension request
    func respond(to request: Self) -> Self? {
        switch self {
        case .perMessageDeflate(let maxWindow, let noContextTakeover):
            switch request {
            case .perMessageDeflate(let requestedMaxWindow, let requestedNoContextTakeover):
                let responseMaxWindow: Int?
                if let maxWindow = maxWindow {
                    if let requestedMaxWindow = requestedMaxWindow {
                        responseMaxWindow = maxWindow < requestedMaxWindow ? maxWindow : requestedMaxWindow
                    } else {
                        responseMaxWindow = maxWindow
                    }
                } else {
                    responseMaxWindow = requestedMaxWindow
                }
                let responseNoContextTakeover = noContextTakeover || requestedNoContextTakeover
                return .perMessageDeflate(maxWindow: responseMaxWindow, noContextTakeover: responseNoContextTakeover)
            }
        }
    }

    /// Construct header value for extension
    /// - Parameter type: client or server
    /// - Returns: `Sec-WebSocket-Extensions` header
    public func header(type: HBWebSocket.SocketType) -> String {
        switch self {
        case .perMessageDeflate(let maxWindow, let noContextTakeover):
            switch type {
            case .server:
                var header = "permessage-deflate"
                if let maxWindow = maxWindow {
                    header += ";client_max_window_bits(\(maxWindow))"
                }
                if noContextTakeover {
                    header += ";client_no_context_takeover"
                }
                return header
            case .client:
                var header = "permessage-deflate"
                if let maxWindow = maxWindow {
                    header += ";server_max_window_bits(\(maxWindow))"
                }
                if noContextTakeover {
                    header += ";server_no_context_takeover"
                }
                return header
            }
        }
    }

    /// Parse all `Sec-WebSocket-Extensions` header values
    /// - Parameters:
    ///   - headers: headers coming from other
    ///   - type: client or server
    /// - Returns: Array of extensions
    public static func parseHeaders(_ headers: HTTPHeaders, type: HBWebSocket.SocketType) -> [WebSocketExtension] {
        headers["Sec-WebSocket-Extensions"].compactMap { .init(from: $0, type: type) }
    }
}

extension Array where Element == WebSocketExtension {
    func respond(to requestedExtensions: [WebSocketExtension]) -> [WebSocketExtension] {
        return self.compactMap { element in
            for ext in requestedExtensions {
                if let response = element.respond(to: ext) {
                    return response
                }
            }
            return nil
        }
    }
}