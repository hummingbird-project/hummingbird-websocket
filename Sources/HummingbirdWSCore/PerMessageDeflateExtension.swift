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

class PerMessageDeflateExtension: HBWebSocketExtension {
    struct Configuration {
        let sendMaxWindow: Int?
        let sendNoContextTakeover: Bool
        let receiveMaxWindow: Int?
        let receiveNoContextTakeover: Bool
    }

    private let decompressor: any NIODecompressor
    private let compressor: any NIOCompressor
    private let receiveNoContextTakeover: Bool
    private let sendNoContextTakeover: Bool

    required init(configuration: Configuration) throws {
        self.decompressor = CompressionAlgorithm.rawDeflate.decompressor(windowBits: configuration.receiveMaxWindow ?? 15)
        self.compressor = CompressionAlgorithm.rawDeflate.compressor(windowBits: configuration.sendMaxWindow ?? 15)
        self.receiveNoContextTakeover = configuration.receiveNoContextTakeover
        self.sendNoContextTakeover = configuration.sendNoContextTakeover

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
            frame.data = try frame.data.decompressStream(with: self.decompressor, maxSize: 1 << 14, allocator: ws.channel.allocator)
            if self.receiveNoContextTakeover {
                try self.decompressor.resetStream()
            }
        }
        return frame
    }

    func processSentFrame(_ frame: WebSocketFrame, ws: HBWebSocket) throws -> WebSocketFrame {
        var frame = frame
        if frame.data.readableBytes > 16 {
            frame.rsv1 = true
            frame.data = try frame.data.compressStream(with: self.compressor, flush: .finish, allocator: ws.channel.allocator)
            if self.sendNoContextTakeover {
                try self.compressor.resetStream()
            }
        }
        return frame
    }
}
