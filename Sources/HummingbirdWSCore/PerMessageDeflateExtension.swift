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
import NIOCore
import NIOWebSocket

struct PerMessageDeflateExtensionBuilder: HBWebSocketExtensionBuilder {
    static var name = "permessage-deflate"

    let clientMaxWindow: Int?
    let clientNoContextTakeover: Bool
    let serverMaxWindow: Int?
    let serverNoContextTakeover: Bool

    internal init(clientMaxWindow: Int? = nil, clientNoContextTakeover: Bool = false, serverMaxWindow: Int? = nil, serverNoContextTakeover: Bool = false) {
        self.clientMaxWindow = clientMaxWindow
        self.clientNoContextTakeover = clientNoContextTakeover
        self.serverMaxWindow = serverMaxWindow
        self.serverNoContextTakeover = serverNoContextTakeover
    }

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

    func responseConfiguration(to request: WebSocketExtensionHTTPParameters) -> PerMessageDeflateExtension.Configuration {
        let serverMaxWindowParam = request.parameters["server_max_window_bits"]
        let serverNoContextTakeoverParam = request.parameters["server_no_context_takeover"] != nil
        let clientMaxWindowParam = request.parameters["client_max_window_bits"]
        let clientNoContextTakeoverParam = request.parameters["client_no_context_takeover"] != nil

        return PerMessageDeflateExtension.Configuration(
            sendMaxWindow: min(serverMaxWindowParam?.integer, self.serverMaxWindow) ?? self.serverMaxWindow,
            sendNoContextTakeover: serverNoContextTakeoverParam || self.serverNoContextTakeover,
            receiveMaxWindow: min(clientMaxWindowParam?.integer, self.clientMaxWindow) ?? clientMaxWindowParam?.integer ?? (clientMaxWindowParam != nil ? self.clientMaxWindow : nil),
            receiveNoContextTakeover: clientNoContextTakeoverParam || self.clientNoContextTakeover
        )
    }

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

    func serverExtension(from request: WebSocketExtensionHTTPParameters) throws -> (HBWebSocketExtension)? {
        let configuration = self.responseConfiguration(to: request)
        return try PerMessageDeflateExtension(configuration: configuration)
    }

    func clientExtension(from request: WebSocketExtensionHTTPParameters) throws -> (HBWebSocketExtension)? {
        let clientMaxWindowParam = request.parameters["client_max_window_bits"]?.integer
        let clientNoContextTakeoverParam = request.parameters["client_no_context_takeover"] != nil
        let serverMaxWindowParam = request.parameters["server_max_window_bits"]?.integer
        let serverNoContextTakeoverParam = request.parameters["server_no_context_takeover"] != nil
        return try PerMessageDeflateExtension(configuration: .init(
            sendMaxWindow: clientMaxWindowParam,
            sendNoContextTakeover: clientNoContextTakeoverParam,
            receiveMaxWindow: serverMaxWindowParam,
            receiveNoContextTakeover: serverNoContextTakeoverParam
        ))
    }
}

final class PerMessageDeflateExtension: HBWebSocketExtension {
    enum SendState {
        case idle
        case sendingMessage
    }

    struct Configuration {
        let sendMaxWindow: Int?
        let sendNoContextTakeover: Bool
        let receiveMaxWindow: Int?
        let receiveNoContextTakeover: Bool
    }

    private let decompressor: any NIODecompressor
    private let compressor: any NIOCompressor
    let configuration: Configuration
    var sendState: SendState

    required init(configuration: Configuration) throws {
        self.decompressor = CompressionAlgorithm.rawDeflate.decompressor(windowBits: configuration.receiveMaxWindow ?? 15)
        self.compressor = CompressionAlgorithm.rawDeflate.compressor(windowBits: configuration.sendMaxWindow ?? 15)
        self.configuration = configuration
        self.sendState = .idle

        try self.decompressor.startStream()
        try self.compressor.startStream()
    }

    deinit {
        try? compressor.finishStream()
        try? decompressor.finishStream()
    }

    func processReceivedFrame(_ frame: WebSocketFrame, ws: HBWebSocket) throws -> WebSocketFrame {
        var frame = frame
        if frame.rsv1 {
            precondition(frame.fin, "Only concatenated frames with fin set can be processed by the permessage-deflate extension")
            frame.data.writeBytes([0, 0, 255, 255])
            frame.data = try frame.data.decompressStream(with: self.decompressor, maxSize: ws.maxFrameSize, allocator: ws.channel.allocator)
            if self.configuration.receiveNoContextTakeover {
                try self.decompressor.resetStream()
            }
        }
        return frame
    }

    func processFrameToSend(_ frame: WebSocketFrame, ws: HBWebSocket) throws -> WebSocketFrame {
        // if the frame is larger than 16 bytes, we haven't received a final frame or we are in the process of sending a message
        // compress the data
        if frame.data.readableBytes > 16 || !frame.fin || self.sendState != .idle, frame.opcode == .text || frame.opcode == .binary {
            var newFrame = frame
            if self.sendState == .idle {
                newFrame.rsv1 = true
                self.sendState = .sendingMessage
            }
            newFrame.data = try newFrame.data.compressStream(with: self.compressor, flush: .sync, allocator: ws.channel.allocator)
            // if final frame then remove last four bytes 0x00 0x00 0xff 0xff (see  https://datatracker.ietf.org/doc/html/rfc7692#section-7.2.1)
            if newFrame.fin {
                newFrame.data = newFrame.data.getSlice(at: newFrame.data.readerIndex, length: newFrame.data.readableBytes - 4) ?? newFrame.data
                self.sendState = .idle
                if self.configuration.sendNoContextTakeover {
                    try self.compressor.resetStream()
                }
            }
            return newFrame
        }
        return frame
    }
}

extension HBWebSocketExtensionFactory {
    ///  permessage-deflate websocket extension
    /// - Parameters:
    ///   - maxWindow: Max window to be used for decompression and compression
    ///   - noContextTakeover: Should we reset window on every message
    public static func perMessageDeflate(maxWindow: Int? = nil, noContextTakeover: Bool = false) -> HBWebSocketExtensionFactory {
        return .init {
            PerMessageDeflateExtensionBuilder(
                clientMaxWindow: maxWindow,
                clientNoContextTakeover: noContextTakeover,
                serverMaxWindow: maxWindow,
                serverNoContextTakeover: noContextTakeover
            )
        }
    }

    ///  permessage-deflate websocket extension
    /// - Parameters:
    ///   - maxWindow: Max window to be used for decompression and compression
    ///   - noContextTakeover: Should we reset window on every message
    public static func perMessageDeflate(
        clientMaxWindow: Int? = nil,
        clientNoContextTakeover: Bool = false,
        serverMaxWindow: Int? = nil,
        serverNoContextTakeover: Bool = false
    ) -> HBWebSocketExtensionFactory {
        return .init {
            PerMessageDeflateExtensionBuilder(
                clientMaxWindow: clientMaxWindow,
                clientNoContextTakeover: clientNoContextTakeover,
                serverMaxWindow: serverMaxWindow,
                serverNoContextTakeover: serverNoContextTakeover
            )
        }
    }
}
