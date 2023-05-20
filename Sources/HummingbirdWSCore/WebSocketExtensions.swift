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

public protocol HBWebSocketExtensionBuilder: Sendable {
    static var name: String { get }
    func clientRequestHeader() -> String
    func serverReponseHeader(to: WebSocketExtensionHTTPParameters) -> String?
    func serverExtension(from: WebSocketExtensionHTTPParameters) throws -> (any HBWebSocketExtension)?
    func clientExtension(from: WebSocketExtensionHTTPParameters) throws -> (any HBWebSocketExtension)?
}

extension HBWebSocketExtensionBuilder {
    public func serverResponseHeader(to requests: [WebSocketExtensionHTTPParameters]) -> String? {
        for request in requests {
            guard request.name == Self.name else { continue }
            if let response = serverReponseHeader(to: request) {
                return response
            }
        }
        return nil
    }

    public func serverExtension(from requests: [WebSocketExtensionHTTPParameters]) throws -> (any HBWebSocketExtension)? {
        for request in requests {
            guard request.name == Self.name else { continue }
            if let ext = try serverExtension(from: request) {
                return ext
            }
        }
        return nil
    }

    public func clientExtension(from requests: [WebSocketExtensionHTTPParameters]) throws -> (any HBWebSocketExtension)? {
        for request in requests {
            guard request.name == Self.name else { continue }
            if let ext = try clientExtension(from: request) {
                return ext
            }
        }
        return nil
    }
}

/// Build WebSocket extension builder
public struct HBWebSocketExtensionFactory: Sendable {
    public let build: @Sendable () -> any HBWebSocketExtensionBuilder

    public init(_ build: @escaping @Sendable () -> any HBWebSocketExtensionBuilder) {
        self.build = build
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
func min(_ a: Int?, _ b: Int?) -> Int? {
    if case .some(let a2) = a, case .some(let b2) = b {
        return min(a2, b2)
    }
    return nil
}
