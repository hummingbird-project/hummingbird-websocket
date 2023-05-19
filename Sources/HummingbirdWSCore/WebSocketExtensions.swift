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

public protocol HBWebSocketExtension {
    associatedtype Configuration

    init(configuration: Configuration) throws
    func processReceivedFrame(_ frame: WebSocketFrame, ws: HBWebSocket) throws -> WebSocketFrame
    func processSentFrame(_ frame: WebSocketFrame, ws: HBWebSocket) throws -> WebSocketFrame
}

public enum WebSocketExtensionConfig: Sendable {
    case perMessageDeflate(maxWindow: Int? = 15, noContextTakeover: Bool)

    /// Negotiation response to extension request
    public func respond(to request: WebSocketExtensionHTTPParameters) -> WebSocketExtension? {
        switch self {
        case .perMessageDeflate(let maxWindow, let noContextTakeover):
            switch request {
            case .perMessageDeflate(let sendMaxWindow, let sendNoContextTakeover, let receiveMaxWindow, let receiveNoContextTakeover):
                return .perMessageDeflate(
                    sendMaxWindow: min(sendMaxWindow, maxWindow),
                    sendNoContextTakeover: sendNoContextTakeover || noContextTakeover,
                    receiveMaxWindow: min(receiveMaxWindow, maxWindow) ?? receiveMaxWindow,
                    receiveNoContextTakeover: receiveNoContextTakeover || noContextTakeover
                )
            }
        }
    }

    /// Construct header value for extension
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
}

public enum WebSocketExtension: Sendable, Equatable {
    case perMessageDeflate(sendMaxWindow: Int?, sendNoContextTakeover: Bool, receiveMaxWindow: Int?, receiveNoContextTakeover: Bool)

    /// Construct header value for extension
    /// - Parameter type: client or server
    /// - Returns: `Sec-WebSocket-Extensions` header
    public func serverResponseHeader() -> String {
        switch self {
        case .perMessageDeflate(let sendMaxWindow, let sendNoContextTakeover, let receiveMaxWindow, let receiveNoContextTakeover):
            var header = "permessage-deflate"
            if let maxWindow = sendMaxWindow {
                header += ";server_max_window_bits=\(maxWindow)"
            }
            if sendNoContextTakeover {
                header += ";server_no_context_takeover"
            }
            if let maxWindow = receiveMaxWindow {
                header += ";client_max_window_bits=\(maxWindow)"
            }
            if receiveNoContextTakeover {
                header += ";client_no_context_takeover"
            }
            return header
        }
    }

    public func getExtension() throws -> any HBWebSocketExtension {
        switch self {
        case .perMessageDeflate(let sendMaxWindow, let sendNoContextTakeover, let receiveMaxWindow, let receiveNoContextTakeover):
            return try PerMessageDeflateExtension(
                configuration: .init(
                    sendMaxWindow: sendMaxWindow,
                    sendNoContextTakeover: sendNoContextTakeover,
                    receiveMaxWindow: receiveMaxWindow,
                    receiveNoContextTakeover: receiveNoContextTakeover
                )
            )
        }
    }
}

public enum WebSocketExtensionHTTPParameters: Sendable, Equatable {
    case perMessageDeflate(sendMaxWindow: Int?, sendNoContextTakeover: Bool, receiveMaxWindow: Int?, receiveNoContextTakeover: Bool)

    /// Initialise WebSocketExtension from header value sent to either client or server
    /// - Parameters:
    ///   - header: header value
    ///   - type: client or server
    init?<S: StringProtocol>(from header: S, from type: HBWebSocket.SocketType) {
        var parameters = header.split(separator: ";", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }[...]
        switch parameters.first {
        case "permessage-deflate":
            var sendMaxWindow: Int?
            var receiveMaxWindow: Int?
            var sendNoContextTakeover = false
            var receiveNoContextTakeover = false

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
                    case ("server_max_window_bits", .client), ("client_max_window_bits", .server):
                        guard let valueString = value, let valueNumber = Int(valueString) else { return nil }
                        sendMaxWindow = valueNumber

                    case ("client_max_window_bits", .client):
                        receiveMaxWindow = value.map { Int($0) } ?? 15

                    case ("server_max_window_bits", .server):
                        guard let valueString = value, let valueNumber = Int(valueString) else { return nil }
                        receiveMaxWindow = valueNumber

                    case ("server_no_context_takeover", .client), ("client_no_context_takeover", .server):
                        sendNoContextTakeover = true

                    case ("client_no_context_takeover", .client), ("server_no_context_takeover", .server):
                        receiveNoContextTakeover = true

                    default:
                        return nil
                    }
                }
                parameters = parameters.dropFirst()
            }
            guard sendMaxWindow == nil || (9...15).contains(sendMaxWindow!) else { return nil }
            guard receiveMaxWindow == nil || (9...15).contains(receiveMaxWindow!) else { return nil }
            self = .perMessageDeflate(
                sendMaxWindow: sendMaxWindow,
                sendNoContextTakeover: sendNoContextTakeover,
                receiveMaxWindow: receiveMaxWindow,
                receiveNoContextTakeover: receiveNoContextTakeover
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
    public static func parseHeaders(_ headers: HTTPHeaders, from type: HBWebSocket.SocketType) -> [WebSocketExtensionHTTPParameters] {
        let extHeaders = headers["Sec-WebSocket-Extensions"].flatMap { $0.split(separator: ",") }
        return extHeaders.compactMap { .init(from: $0, from: type) }
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

private func min(_ a: Int?, _ b: Int?) -> Int? {
    if case .some(let a2) = a, case .some(let b2) = b {
        return min(a2, b2)
    }
    return nil
}
