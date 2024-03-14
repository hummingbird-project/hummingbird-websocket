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

import CompressNIO
import HummingbirdWSCore
import NIOCore
import NIOWebSocket

/// PerMessageDeflate Websocket extension builder
struct PerMessageDeflateExtensionBuilder: WebSocketExtensionBuilder {
    static var name = "permessage-deflate"

    let clientMaxWindow: Int?
    let clientNoContextTakeover: Bool
    let serverMaxWindow: Int?
    let serverNoContextTakeover: Bool
    let compressionLevel: Int?
    let memoryLevel: Int?

    init(
        clientMaxWindow: Int? = nil,
        clientNoContextTakeover: Bool = false,
        serverMaxWindow: Int? = nil,
        serverNoContextTakeover: Bool = false,
        compressionLevel: Int? = nil,
        memoryLevel: Int? = nil
    ) {
        self.clientMaxWindow = clientMaxWindow
        self.clientNoContextTakeover = clientNoContextTakeover
        self.serverMaxWindow = serverMaxWindow
        self.serverNoContextTakeover = serverNoContextTakeover
        self.compressionLevel = compressionLevel
        self.memoryLevel = memoryLevel
    }

    /// Return client request header
    func clientRequestHeader() -> String {
        var header = "permessage-deflate"
        if let maxWindow = self.clientMaxWindow {
            header += ";client_max_window_bits=\(maxWindow)"
        }
        if self.clientNoContextTakeover {
            header += ";client_no_context_takeover"
        }
        if let maxWindow = self.serverMaxWindow {
            header += ";server_max_window_bits=\(maxWindow)"
        }
        if self.serverNoContextTakeover {
            header += ";server_no_context_takeover"
        }
        return header
    }

    /// Return server response header, given a client request
    /// - Parameter request: Client request header parameters
    /// - Returns: Server response parameters
    func serverReponseHeader(to request: WebSocketExtensionHTTPParameters) -> String? {
        let configuration = self.responseConfiguration(to: request)
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
    }

    /// Create server PerMessageDeflateExtension based off request headers
    /// - Parameters:
    ///   - request: Client request
    ///   - eventLoop: EventLoop it is bound to
    func serverExtension(from request: WebSocketExtensionHTTPParameters, eventLoop: EventLoop) throws -> (WebSocketExtension)? {
        let configuration = self.responseConfiguration(to: request)
        return try PerMessageDeflateExtension(configuration: configuration, eventLoop: eventLoop)
    }

    /// Create client PerMessageDeflateExtension based off response headers
    /// - Parameters:
    ///   - response: Server response
    ///   - eventLoop: EventLoop it is bound to
    func clientExtension(from response: WebSocketExtensionHTTPParameters, eventLoop: EventLoop) throws -> WebSocketExtension? {
        let clientMaxWindowParam = response.parameters["client_max_window_bits"]?.integer
        let clientNoContextTakeoverParam = response.parameters["client_no_context_takeover"] != nil
        let serverMaxWindowParam = response.parameters["server_max_window_bits"]?.integer
        let serverNoContextTakeoverParam = response.parameters["server_no_context_takeover"] != nil
        return try PerMessageDeflateExtension(configuration: .init(
            receiveMaxWindow: serverMaxWindowParam,
            receiveNoContextTakeover: serverNoContextTakeoverParam,
            sendMaxWindow: clientMaxWindowParam,
            sendNoContextTakeover: clientNoContextTakeoverParam,
            compressionLevel: self.compressionLevel,
            memoryLevel: self.memoryLevel
        ), eventLoop: eventLoop)
    }

    private func responseConfiguration(to request: WebSocketExtensionHTTPParameters) -> PerMessageDeflateExtension.Configuration {
        let requestServerMaxWindow = request.parameters["server_max_window_bits"]
        let requestServerNoContextTakeover = request.parameters["server_no_context_takeover"] != nil
        let requestClientMaxWindow = request.parameters["client_max_window_bits"]
        let requestClientNoContextTakeover = request.parameters["client_no_context_takeover"] != nil

        let receiveMaxWindow: Int?
            // calculate client max window. If parameter doesn't exist then server cannot set it, if it does
            // exist then the value should be set to minimum of both values, or the value of the other if
            // one is nil
            = if let requestClientMaxWindow
        {
            optionalMin(requestClientMaxWindow.integer, self.clientMaxWindow)
        } else {
            nil
        }

        return PerMessageDeflateExtension.Configuration(
            receiveMaxWindow: receiveMaxWindow,
            receiveNoContextTakeover: requestClientNoContextTakeover || self.clientNoContextTakeover,
            sendMaxWindow: optionalMin(requestServerMaxWindow?.integer, self.serverMaxWindow),
            sendNoContextTakeover: requestServerNoContextTakeover || self.serverNoContextTakeover,
            compressionLevel: self.compressionLevel,
            memoryLevel: self.memoryLevel
        )
    }
}

/// PerMessageDeflate websocket extension
///
/// Uses deflate to compress messages sent across a WebSocket
/// See RFC 7692 for more details https://www.rfc-editor.org/rfc/rfc7692
struct PerMessageDeflateExtension: WebSocketExtension {
    enum SendState: Sendable {
        case idle
        case sendingMessage
    }

    struct Configuration: Sendable {
        let receiveMaxWindow: Int?
        let receiveNoContextTakeover: Bool
        let sendMaxWindow: Int?
        let sendNoContextTakeover: Bool
        let compressionLevel: Int?
        let memoryLevel: Int?
    }

    /// Internal mutable state and referenced types, that cannot be set to Sendable
    class InternalState {
        fileprivate let decompressor: any NIODecompressor
        fileprivate let compressor: any NIOCompressor
        fileprivate var sendState: SendState

        init(configuration: Configuration) throws {
            self.decompressor = CompressionAlgorithm.deflate(
                configuration: .init(
                    windowSize: numericCast(configuration.receiveMaxWindow ?? 15)
                )
            ).decompressor
            // compression level -1 will setup the default compression level, 8 is the default memory level
            self.compressor = CompressionAlgorithm.deflate(
                configuration: .init(
                    windowSize: numericCast(configuration.sendMaxWindow ?? 15),
                    compressionLevel: configuration.compressionLevel.map { numericCast($0) } ?? -1,
                    memoryLevel: configuration.memoryLevel.map { numericCast($0) } ?? 8
                )
            ).compressor
            self.sendState = .idle
            try self.decompressor.startStream()
            try self.compressor.startStream()
        }

        func shutdown() {
            try? self.compressor.finishStream()
            try? self.decompressor.finishStream()
        }
    }

    let configuration: Configuration
    let internalState: NIOLoopBound<InternalState>

    init(configuration: Configuration, eventLoop: EventLoop) throws {
        self.configuration = configuration
        self.internalState = try .init(.init(configuration: configuration), eventLoop: eventLoop)
    }

    func shutdown() {
        self.internalState.value.shutdown()
    }

    func processReceivedFrame(_ frame: WebSocketFrame, ws: WebSocket) throws -> WebSocketFrame {
        var frame = frame
        if frame.rsv1 {
            let state = self.internalState.value
            precondition(frame.fin, "Only concatenated frames with fin set can be processed by the permessage-deflate extension")
            // Reinstate last four bytes 0x00 0x00 0xff 0xff that were removed in the frame
            // send (see  https://datatracker.ietf.org/doc/html/rfc7692#section-7.2.2).
            frame.data.writeBytes([0, 0, 255, 255])
            frame.data = try frame.data.decompressStream(with: state.decompressor, maxSize: ws.maxFrameSize, allocator: ws.channel.allocator)
            if self.configuration.receiveNoContextTakeover {
                try state.decompressor.resetStream()
            }
        }
        return frame
    }

    func processFrameToSend(_ frame: WebSocketFrame, ws: WebSocket) throws -> WebSocketFrame {
        let state = self.internalState.value
        // if the frame is larger than 16 bytes, we haven't received a final frame or we are in the process of sending a message
        // compress the data
        let shouldWeCompress = frame.data.readableBytes > 16 || !frame.fin || state.sendState != .idle
        let isCorrectType = frame.opcode == .text || frame.opcode == .binary
        if shouldWeCompress, isCorrectType {
            var newFrame = frame
            if state.sendState == .idle {
                newFrame.rsv1 = true
                state.sendState = .sendingMessage
            }
            newFrame.data = try newFrame.data.compressStream(with: state.compressor, flush: .sync, allocator: ws.channel.allocator)
            // if final frame then remove last four bytes 0x00 0x00 0xff 0xff
            // (see  https://datatracker.ietf.org/doc/html/rfc7692#section-7.2.1)
            if newFrame.fin {
                newFrame.data = newFrame.data.getSlice(at: newFrame.data.readerIndex, length: newFrame.data.readableBytes - 4) ?? newFrame.data
                state.sendState = .idle
                if self.configuration.sendNoContextTakeover {
                    try state.compressor.resetStream()
                }
            }
            return newFrame
        }
        return frame
    }
}

extension WebSocketExtensionFactory {
    ///  permessage-deflate websocket extension
    /// - Parameters:
    ///   - maxWindow: Max window to be used for decompression and compression
    ///   - noContextTakeover: Should we reset window on every message
    public static func perMessageDeflate(maxWindow: Int? = nil, noContextTakeover: Bool = false) -> WebSocketExtensionFactory {
        return .init {
            PerMessageDeflateExtensionBuilder(
                clientMaxWindow: maxWindow,
                clientNoContextTakeover: noContextTakeover,
                serverMaxWindow: maxWindow,
                serverNoContextTakeover: noContextTakeover,
                compressionLevel: nil,
                memoryLevel: nil
            )
        }
    }

    ///  permessage-deflate websocket extension
    /// - Parameters:
    ///   - clientMaxWindow: Max window to be used for client compression
    ///   - clientNoContextTakeover: Should client reset window on every message
    ///   - serverMaxWindow: Max window to be used for server compression
    ///   - serverNoContextTakeover: Should server reset window on every message
    ///   - compressionLevel: Zlib compression level. Value between 0 and 9 where 1 gives best speed, 9 gives
    ///         give best compression and 0 gives no compression.
    ///   - memoryLevel: Defines how much memory should be given to compression. Value between 1 and 9 where 1
    ///         uses least memory and 9 give best compression and optimal speed.
    public static func perMessageDeflate(
        clientMaxWindow: Int? = nil,
        clientNoContextTakeover: Bool = false,
        serverMaxWindow: Int? = nil,
        serverNoContextTakeover: Bool = false,
        compressionLevel: Int? = nil,
        memoryLevel: Int? = nil
    ) -> WebSocketExtensionFactory {
        return .init {
            PerMessageDeflateExtensionBuilder(
                clientMaxWindow: clientMaxWindow,
                clientNoContextTakeover: clientNoContextTakeover,
                serverMaxWindow: serverMaxWindow,
                serverNoContextTakeover: serverNoContextTakeover,
                compressionLevel: compressionLevel,
                memoryLevel: memoryLevel
            )
        }
    }
}

/// Minimum of two optional integers.
///
/// Returns the other is one of them is nil
private func optionalMin(_ a: Int?, _ b: Int?) -> Int? {
    switch (a, b) {
    case (.some(let a), .some(let b)):
        return min(a, b)
    case (.some(a), .none):
        return a
    case (.none, .some(b)):
        return b
    default:
        return nil
    }
}
