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

import AsyncAlgorithms
import NIOCore
import NIOWebSocket

public typealias WebSocketHandlerInbound = AsyncChannel<WebSocketData>
public struct WebSocketHandlerOutbound {
    let webSocket: HBWebSocket
    let outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>

    func write(_ data: WebSocketData) async throws {
        try Task.checkCancellation()
        switch data {
        case .text(let string):
            let buffer = self.webSocket.asyncChannel.channel.allocator.buffer(string: string)
            try await self.webSocket.send(buffer: buffer, opcode: .text, fin: true, outbound: self.outbound)
        case .binary(let buffer):
            try await self.webSocket.send(buffer: buffer, opcode: .binary, fin: true, outbound: self.outbound)
        }
    }
}
public typealias WebSocketHandler = @Sendable (WebSocketHandlerInbound, WebSocketHandlerOutbound) async throws -> Void