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

public enum WebSocketExtensionConfig: Sendable {
    case perMessageDeflate(maxWindow: Int? = 15, noContextTakeover: Bool)

    /// Negotiation response to extension request
    public func respond(to request: WebSocketExtensionHTTPParameters) -> WebSocketExtension? {
        switch self {
        case .perMessageDeflate(let maxWindow, let noContextTakeover):
            switch request {
            case .perMessageDeflate(let requestedMaxWindow, let requestedNoContextTakeover, let supportsMaxWindow, let supportsNoContextTakeover):
                return .perMessageDeflate(
                    requestMaxWindow: requestedMaxWindow,
                    requestNoContextTakeover: requestedNoContextTakeover || noContextTakeover,
                    responseMaxWindow: supportsMaxWindow ? maxWindow : nil,
                    responseNoContextTakeover: noContextTakeover
                )
            }
        }
    }

    public var requestExtension: WebSocketExtension {
        switch self {
        case .perMessageDeflate(let maxWindow, let noContextTakeover):
            return .perMessageDeflate(requestMaxWindow: maxWindow, requestNoContextTakeover: noContextTakeover, responseMaxWindow: nil, responseNoContextTakeover: false)
        }
    }
}

public enum WebSocketExtension: Sendable, Equatable {
    case perMessageDeflate(requestMaxWindow: Int? = 15, requestNoContextTakeover: Bool, responseMaxWindow: Int? = 15, responseNoContextTakeover: Bool)

    /// Construct header value for extension
    /// - Parameter type: client or server
    /// - Returns: `Sec-WebSocket-Extensions` header
    public func header(type: HBWebSocket.SocketType) -> String {
        switch self {
        case .perMessageDeflate(let maxWindow, let noContextTakeover, let responseMaxWindow, let responseNoContextTakeover):
            switch type {
            case .server:
                var header = "permessage-deflate"
                if let maxWindow = responseMaxWindow {
                    header += ";server_max_window_bits=\(maxWindow)"
                }
                if responseNoContextTakeover {
                    header += ";server_no_context_takeover"
                }
                if let maxWindow = maxWindow {
                    header += ";client_max_window_bits=\(maxWindow)"
                }
                if noContextTakeover {
                    header += ";client_no_context_takeover"
                }
                return header
            case .client:
                var header = "permessage-deflate"
                if let maxWindow = responseMaxWindow {
                    header += ";client_max_window_bits=\(maxWindow)"
                }
                if responseNoContextTakeover {
                    header += ";client_no_context_takeover"
                }
                if let maxWindow = maxWindow {
                    header += ";server_max_window_bits=\(maxWindow)"
                }
                if noContextTakeover {
                    header += ";server_no_context_takeover"
                }
                return header
            }
        }
    }
}

public enum WebSocketExtensionHTTPParameters: Sendable, Equatable {
    case perMessageDeflate(maxWindow: Int? = 15, noContextTakeover: Bool, supportsMaxWindow: Bool, supportsNoContextTakeover: Bool)

    /// Initialise WebSocketExtension from header value sent to either client or server
    /// - Parameters:
    ///   - header: header value
    ///   - type: client or server
    init?<S: StringProtocol>(from header: S, type: HBWebSocket.SocketType) {
        var parameters = header.split(separator: ";", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }[...]
        switch parameters.first {
        case "permessage-deflate":
            var maxWindow: Int?
            var noContextTakeover = false
            var supportsMaxWindow = false
            var supportsNoContextTakeover = false

            parameters = parameters.dropFirst()
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
                    case ("client_max_window_bits", .client), ("server_max_window_bits", .server):
                        guard let valueString = value, let valueNumber = Int(valueString) else { return nil }
                        maxWindow = valueNumber

                    case ("client_max_window_bits", .server), ("server_max_window_bits", .client):
                        guard value == nil else { return nil }
                        supportsMaxWindow = true

                    case ("server_no_context_takeover", .server), ("client_no_context_takeover", .client):
                        noContextTakeover = true

                    case ("server_no_context_takeover", .client), ("client_no_context_takeover", .server):
                        supportsNoContextTakeover = true

                    default:
                        return nil
                    }
                }
                parameters = parameters.dropFirst()
            }
            guard maxWindow == nil || (9...15).contains(maxWindow!) else { return nil }
            self = .perMessageDeflate(
                maxWindow: maxWindow,
                noContextTakeover: noContextTakeover,
                supportsMaxWindow: supportsMaxWindow,
                supportsNoContextTakeover: supportsNoContextTakeover
            )
        default:
            return nil
        }
    }

    /// Parse all `Sec-WebSocket-Extensions` header values
    /// - Parameters:
    ///   - headers: headers coming from other
    ///   - type: client or server
    /// - Returns: Array of extensions
    public static func parseHeaders(_ headers: HTTPHeaders, type: HBWebSocket.SocketType) -> [WebSocketExtensionHTTPParameters] {
        let extHeaders = headers["Sec-WebSocket-Extensions"].flatMap { $0.split(separator: ",") }
        return extHeaders.compactMap { .init(from: $0, type: type) }
    }
}

extension Array where Element == WebSocketExtensionConfig {
    public func respond(to requestedExtensions: [WebSocketExtensionHTTPParameters]) -> [WebSocketExtension] {
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
