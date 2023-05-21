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

    let maxWindow: Int?
    let noContextTakeover: Bool

    init(maxWindow: Int? = 15, noContextTakeover: Bool = true) {
        self.maxWindow = maxWindow
        self.noContextTakeover = noContextTakeover
    }

    func clientRequestHeader() -> String {
        var header = "permessage-deflate"
        if let maxWindow = self.maxWindow {
            header += ";client_max_window_bits=\(maxWindow)"
        }
        if self.noContextTakeover {
            header += ";client_no_context_takeover"
        }
        if let maxWindow = self.maxWindow {
            header += ";server_max_window_bits=\(maxWindow)"
        }
        if self.noContextTakeover {
            header += ";server_no_context_takeover"
        }
        return header
    }

    func serverReponseHeader(to request: WebSocketExtensionHTTPParameters) -> String? {
        let sendMaxWindow = request.parameters["server_max_window_bits"]
        let sendNoContextTakeover = request.parameters["server_no_context_takeover"] != nil
        let receiveMaxWindow = request.parameters["client_max_window_bits"]
        let receiveNoContextTakeover = request.parameters["client_no_context_takeover"] != nil

        let configuration = PerMessageDeflateExtension.Configuration(
            sendMaxWindow: min(sendMaxWindow?.integer, maxWindow) ?? maxWindow,
            sendNoContextTakeover: sendNoContextTakeover || self.noContextTakeover,
            receiveMaxWindow: min(receiveMaxWindow?.integer, maxWindow) ?? receiveMaxWindow?.integer ?? (receiveMaxWindow != nil ? maxWindow : nil),
            receiveNoContextTakeover: receiveNoContextTakeover || self.noContextTakeover
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
    }

    func serverExtension(from request: WebSocketExtensionHTTPParameters) throws -> (HBWebSocketExtension)? {
        let sendMaxWindow = request.parameters["server_max_window_bits"]
        let sendNoContextTakeover = request.parameters["server_no_context_takeover"] != nil
        let receiveMaxWindow = request.parameters["client_max_window_bits"]
        let receiveNoContextTakeover = request.parameters["client_no_context_takeover"] != nil

        let configuration = PerMessageDeflateExtension.Configuration(
            sendMaxWindow: min(sendMaxWindow?.integer, self.maxWindow) ?? self.maxWindow,
            sendNoContextTakeover: sendNoContextTakeover || self.noContextTakeover,
            receiveMaxWindow: min(receiveMaxWindow?.integer, self.maxWindow) ?? (receiveMaxWindow != nil ? self.maxWindow : nil),
            receiveNoContextTakeover: receiveNoContextTakeover || self.noContextTakeover
        )
        return try PerMessageDeflateExtension(configuration: configuration)
    }

    func clientExtension(from request: WebSocketExtensionHTTPParameters) throws -> (HBWebSocketExtension)? {
        let sendMaxWindow = request.parameters["client_max_window_bits"]?.integer
        let sendNoContextTakeover = request.parameters["client_no_context_takeover"] != nil
        let receiveMaxWindow = request.parameters["server_max_window_bits"]?.integer
        let receiveNoContextTakeover = request.parameters["server_no_context_takeover"] != nil
        return try PerMessageDeflateExtension(configuration: .init(
            sendMaxWindow: sendMaxWindow,
            sendNoContextTakeover: sendNoContextTakeover,
            receiveMaxWindow: receiveMaxWindow,
            receiveNoContextTakeover: receiveNoContextTakeover
        ))
    }
}

class PerMessageDeflateExtension: HBWebSocketExtension {
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
        var frame = frame
        if frame.data.readableBytes > 16 {
            frame.rsv1 = true
            if self.configuration.sendNoContextTakeover {
                frame.data = try frame.data.compressStream(with: self.compressor, flush: .finish, allocator: ws.channel.allocator)
                try self.compressor.resetStream()
            } else {
                frame.data = try frame.data.compressStream(with: self.compressor, flush: .sync, allocator: ws.channel.allocator)
                if frame.fin {
                    frame.data = frame.data.getSlice(at: frame.data.readerIndex, length: frame.data.readableBytes - 4) ?? frame.data
                }
            }
        }
        return frame
    }
}

extension HBWebSocketExtensionFactory {
    ///  permessage-deflate websocket extension
    /// - Parameters:
    ///   - maxWindow: Max window to be used for decompression and compression
    ///   - noContextTakeover: Should we reset window on every message
    public static func perMessageDeflate(maxWindow: Int? = 15, noContextTakeover: Bool = false) -> HBWebSocketExtensionFactory {
        return .init {
            PerMessageDeflateExtensionBuilder(maxWindow: maxWindow, noContextTakeover: noContextTakeover)
        }
    }
}
