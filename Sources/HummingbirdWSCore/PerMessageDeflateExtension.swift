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

    let sendMaxWindow: Int?
    let sendNoContextTakeover: Bool
    let receiveMaxWindow: Int?
    let receiveNoContextTakeover: Bool

    internal init(sendMaxWindow: Int? = nil, sendNoContextTakeover: Bool = false, receiveMaxWindow: Int? = nil, receiveNoContextTakeover: Bool = false) {
        self.sendMaxWindow = sendMaxWindow
        self.sendNoContextTakeover = sendNoContextTakeover
        self.receiveMaxWindow = receiveMaxWindow
        self.receiveNoContextTakeover = receiveNoContextTakeover
    }

    func clientRequestHeader() -> String {
        var header = "permessage-deflate"
        if let maxWindow = self.sendMaxWindow {
            header += ";client_max_window_bits=\(maxWindow)"
        }
        if self.sendNoContextTakeover {
            header += ";client_no_context_takeover"
        }
        if let maxWindow = self.receiveMaxWindow {
            header += ";server_max_window_bits=\(maxWindow)"
        }
        if self.receiveNoContextTakeover {
            header += ";server_no_context_takeover"
        }
        return header
    }

    func responseConfiguration(to request: WebSocketExtensionHTTPParameters) -> PerMessageDeflateExtension.Configuration {
        let sendMaxWindowParam = request.parameters["server_max_window_bits"]
        let sendNoContextTakeoverParam = request.parameters["server_no_context_takeover"] != nil
        let receiveMaxWindowParam = request.parameters["client_max_window_bits"]
        let receiveNoContextTakeoverParam = request.parameters["client_no_context_takeover"] != nil

        return PerMessageDeflateExtension.Configuration(
            sendMaxWindow: min(sendMaxWindowParam?.integer, sendMaxWindow) ?? sendMaxWindow,
            sendNoContextTakeover: sendNoContextTakeoverParam || self.sendNoContextTakeover,
            receiveMaxWindow: min(receiveMaxWindowParam?.integer, receiveMaxWindow) ?? receiveMaxWindowParam?.integer ?? (receiveMaxWindowParam != nil ? receiveMaxWindow : nil),
            receiveNoContextTakeover: receiveNoContextTakeoverParam || self.receiveNoContextTakeover
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
        let sendMaxWindowParam = request.parameters["client_max_window_bits"]?.integer
        let sendNoContextTakeoverParam = request.parameters["client_no_context_takeover"] != nil
        let receiveMaxWindowParam = request.parameters["server_max_window_bits"]?.integer
        let receiveNoContextTakeoverParam = request.parameters["server_no_context_takeover"] != nil
        return try PerMessageDeflateExtension(configuration: .init(
            sendMaxWindow: sendMaxWindowParam,
            sendNoContextTakeover: sendNoContextTakeoverParam,
            receiveMaxWindow: receiveMaxWindowParam,
            receiveNoContextTakeover: receiveNoContextTakeoverParam
        ))
    }
}

final class PerMessageDeflateExtension: HBWebSocketExtension {
    struct Configuration {
        let sendMaxWindow: Int?
        let sendNoContextTakeover: Bool
        let receiveMaxWindow: Int?
        let receiveNoContextTakeover: Bool
    }

    private let decompressor: any NIODecompressor
    private let compressor: any NIOCompressor
    let configuration: Configuration

    required init(configuration: Configuration) throws {
        self.decompressor = CompressionAlgorithm.rawDeflate.decompressor(windowBits: configuration.receiveMaxWindow ?? 15)
        self.compressor = CompressionAlgorithm.rawDeflate.compressor(windowBits: configuration.sendMaxWindow ?? 15)
        self.configuration = configuration

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
            if self.configuration.receiveNoContextTakeover {
                frame.data = try frame.data.decompressStream(with: self.decompressor, maxSize: 1 << 14, allocator: ws.channel.allocator)
                try self.decompressor.resetStream()
            } else {
                if frame.fin {
                    frame.data.writeBytes([0, 0, 255, 255])
                }
                frame.data = try frame.data.decompressStream(with: self.decompressor, maxSize: 1 << 14, allocator: ws.channel.allocator)
            }
        }
        return frame
    }

    func processFrameToSend(_ frame: WebSocketFrame, ws: HBWebSocket) throws -> WebSocketFrame {
        var newFrame = frame
        if newFrame.data.readableBytes > 16 {
            newFrame.rsv1 = true
            if self.configuration.sendNoContextTakeover {
                newFrame.data = try newFrame.data.compressStream(with: self.compressor, flush: .finish, allocator: ws.channel.allocator)
                try self.compressor.resetStream()
            } else {
                newFrame.data = try newFrame.data.compressStream(with: self.compressor, flush: .sync, allocator: ws.channel.allocator)
                if newFrame.fin {
                    newFrame.data = newFrame.data.getSlice(at: newFrame.data.readerIndex, length: newFrame.data.readableBytes - 4) ?? newFrame.data
                }
            }
        }
        return newFrame.data.readableBytes < frame.data.readableBytes ? newFrame : frame
    }
}

extension HBWebSocketExtensionFactory {
    ///  permessage-deflate websocket extension
    /// - Parameters:
    ///   - maxWindow: Max window to be used for decompression and compression
    ///   - noContextTakeover: Should we reset window on every message
    public static func perMessageDeflate(maxWindow: Int? = 15, noContextTakeover: Bool = false) -> HBWebSocketExtensionFactory {
        return .init {
            PerMessageDeflateExtensionBuilder(
                sendMaxWindow: maxWindow,
                sendNoContextTakeover: noContextTakeover,
                receiveMaxWindow: maxWindow,
                receiveNoContextTakeover: noContextTakeover
            )
        }
    }

    ///  permessage-deflate websocket extension
    /// - Parameters:
    ///   - maxWindow: Max window to be used for decompression and compression
    ///   - noContextTakeover: Should we reset window on every message
    public static func perMessageDeflate(
        sendMaxWindow: Int? = 15,
        sendNoContextTakeover: Bool = false,
        receiveMaxWindow: Int? = 15,
        receiveNoContextTakeover: Bool = false
    ) -> HBWebSocketExtensionFactory {
        return .init {
            PerMessageDeflateExtensionBuilder(
                sendMaxWindow: sendMaxWindow,
                sendNoContextTakeover: sendNoContextTakeover,
                receiveMaxWindow: receiveMaxWindow,
                receiveNoContextTakeover: receiveNoContextTakeover
            )
        }
    }
}
