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
import NIOWebSocket

/// Protocol for WebSocket extension
public protocol HBWebSocketExtension {
    /// Process frame received from websocket
    func processReceivedFrame(_ frame: WebSocketFrame, ws: HBWebSocket) throws -> WebSocketFrame
    /// Process frame about to be sent to websocket
    func processSentFrame(_ frame: WebSocketFrame, ws: HBWebSocket) throws -> WebSocketFrame
}

/// WebSocket extension configuration
public enum WebSocketExtensionConfig: Sendable {
    case perMessageDeflate(maxWindow: Int? = 15, noContextTakeover: Bool)

    /// Construct client request header value for extension
    /// - Parameter type: client or server
    /// - Returns: `Sec-WebSocket-Extensions` header
    public func clientRequestHeader() -> String {
        switch self {
        case .perMessageDeflate(let maxWindow, let noContextTakeover):
            var header = "permessage-deflate"
            if let maxWindow = maxWindow {
                header += ";client_max_window_bits=\(maxWindow)"
            }
            if noContextTakeover {
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

    /// Construct server response header value for extension
    /// - Parameter type: client or server
    /// - Returns: `Sec-WebSocket-Extensions` header
    public func serverResponseHeader(to requests: [WebSocketExtensionHTTPParameters]) -> String? {
        for request in requests {
            switch (self, request.name) {
            case (.perMessageDeflate(let maxWindow, let noContextTakeover), "permessage-deflate"):
                let sendMaxWindow = request.parameters["server_max_window_bits"]
                let sendNoContextTakeover = request.parameters["server_no_context_takeover"] != nil
                let receiveMaxWindow = request.parameters["client_max_window_bits"]
                let receiveNoContextTakeover = request.parameters["client_no_context_takeover"] != nil

                let configuration = PerMessageDeflateExtension.Configuration(
                    sendMaxWindow: min(sendMaxWindow?.integer, maxWindow) ?? maxWindow,
                    sendNoContextTakeover: sendNoContextTakeover || noContextTakeover,
                    receiveMaxWindow: min(receiveMaxWindow?.integer, maxWindow) ?? receiveMaxWindow?.integer ?? maxWindow,
                    receiveNoContextTakeover: receiveNoContextTakeover || noContextTakeover
                )
                var header = "permessage-deflate"
                if let maxWindow = configuration.receiveMaxWindow {
                    header += ";client_max_window_bits=\(maxWindow)"
                }
                if configuration.receiveNoContextTakeover {
                    header += ";client_no_context_takeover"
                }
                if let maxWindow = configuration.sendMaxWindow {
                    header += ";server_max_window_bits=\(maxWindow)"
                }
                if configuration.sendNoContextTakeover {
                    header += ";server_no_context_takeover"
                }
                return header
            default:
                break
            }
        }
        return nil
    }

    /// Construct server extension from client request headers
    /// - Parameter requests: client request headers
    /// - Returns: server extension
    public func serverExtension(from requests: [WebSocketExtensionHTTPParameters]) throws -> (any HBWebSocketExtension)? {
        for request in requests {
            switch self {
            case .perMessageDeflate(let maxWindow, let noContextTakeover):
                switch request.name {
                case "permessage-deflate":
                    let sendMaxWindow = request.parameters["server_max_window_bits"]
                    let sendNoContextTakeover = request.parameters["server_no_context_takeover"] != nil
                    let receiveMaxWindow = request.parameters["client_max_window_bits"]
                    let receiveNoContextTakeover = request.parameters["client_no_context_takeover"] != nil

                    let configuration = PerMessageDeflateExtension.Configuration(
                        sendMaxWindow: min(sendMaxWindow?.integer, maxWindow) ?? maxWindow,
                        sendNoContextTakeover: sendNoContextTakeover || noContextTakeover,
                        receiveMaxWindow: min(receiveMaxWindow?.integer, maxWindow) ?? (receiveMaxWindow != nil ? maxWindow : nil),
                        receiveNoContextTakeover: receiveNoContextTakeover || noContextTakeover
                    )
                    return try PerMessageDeflateExtension(configuration: configuration)
                default:
                    break
                }
            }
        }
        return nil
    }

    ///  Construct client extension from server reponse headers
    /// - Parameter requests: server response headers
    /// - Returns: client extension
    public func clientExtension(from requests: [WebSocketExtensionHTTPParameters]) throws -> HBWebSocketExtension? {
        for request in requests {
            switch self {
            case .perMessageDeflate:
                switch request.name {
                case "permessage-deflate":
                    let sendMaxWindow = request.parameters["client_max_window_bits"]?.integer
                    let sendNoContextTakeover = request.parameters["client_no_context_takeover"] != .null
                    let receiveMaxWindow = request.parameters["server_max_window_bits"]?.integer
                    let receiveNoContextTakeover = request.parameters["server_no_context_takeover"] != .null
                    return try PerMessageDeflateExtension(configuration: .init(
                        sendMaxWindow: sendMaxWindow,
                        sendNoContextTakeover: sendNoContextTakeover,
                        receiveMaxWindow: receiveMaxWindow,
                        receiveNoContextTakeover: receiveNoContextTakeover
                    ))
                default:
                    break
                }
            }
        }
        return nil
    }
}

/// Parsed parameters from `Sec-WebSocket-Extensions` header
public struct WebSocketExtensionHTTPParameters: Sendable, Equatable {
    /// A single parameter
    enum Parameter: Sendable, Equatable {
        // Parameter with a value
        case value(String)
        // Parameter with no value
        case null

        // Convert to optional
        var optional: String? {
            switch self {
            case .value(let string):
                return .some(string)
            case .null:
                return .none
            }
        }

        // Convert to integer
        var integer: Int? {
            switch self {
            case .value(let string):
                return Int(string)
            case .null:
                return .none
            }
        }
    }

    let parameters: [String: Parameter]
    let name: String

    /// initialise WebSocket extension parameters from string
    init?<S: StringProtocol>(from header: S) {
        let split = header.split(separator: ";", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }[...]
        if let name = split.first {
            self.name = name
        } else {
            return nil
        }
        var index = split.index(after: split.startIndex)
        var parameters: [String: Parameter] = [:]
        while index != split.endIndex {
            let keyValue = split[index].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let key = keyValue.first {
                if keyValue.count > 1 {
                    parameters[key] = .value(keyValue[1])
                } else {
                    parameters[key] = .null
                }
            }
            index = split.index(after: index)
        }
        self.parameters = parameters
    }

    /// Parse all `Sec-WebSocket-Extensions` header values
    /// - Parameters:
    ///   - headers: headers coming from other
    ///   - type: client or server
    /// - Returns: Array of extensions
    public static func parseHeaders(_ headers: HTTPHeaders) -> [WebSocketExtensionHTTPParameters] {
        let extHeaders = headers["Sec-WebSocket-Extensions"].flatMap { $0.split(separator: ",") }
        return extHeaders.compactMap { .init(from: $0) }
    }
}

extension WebSocketExtensionHTTPParameters {
    /// Initialiser used by tests
    init(_ name: String, parameters: [String: Parameter]) {
        self.name = name
        self.parameters = parameters
    }
}

/// Minimum of two optional integers.
///
/// Returns nil if either of them is nil
private func min(_ a: Int?, _ b: Int?) -> Int? {
    if case .some(let a2) = a, case .some(let b2) = b {
        return min(a2, b2)
    }
    return nil
}
