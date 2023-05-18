//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2023 the Hummingbird authors
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

/// Enumeration holding WebSocket data
public enum WebSocketData: Equatable, Sendable {
    case text(String)
    case binary(ByteBuffer)
}

/// Sequence of fragmented WebSocket frames.
struct WebSocketFrameSequence {
    enum SequenceType {
        case text
        case binary

        var opcode: WebSocketOpcode {
            switch self {
            case .text:
                return .text
            case .binary:
                return .binary
            }
        }

        func webSocketData(for bytes: ByteBuffer) -> WebSocketData {
            switch self {
            case .text:
                return .text(String(buffer: bytes))
            case .binary:
                return .binary(bytes)
            }
        }
    }

    var buffers: [ByteBuffer]
    var size: Int
    var type: SequenceType
    var rsv1: Bool

    init(type: SequenceType) {
        self.buffers = []
        self.type = type
        self.size = 0
        self.rsv1 = false
    }

    mutating func append(_ frame: WebSocketFrame) {
        assert(frame.opcode == self.type.opcode)
        if self.buffers.isEmpty {
            self.rsv1 = frame.rsv1
        }
        self.buffers.append(frame.unmaskedData)
        self.size += frame.unmaskedData.readableBytes
    }

    var bytes: ByteBuffer {
        if self.buffers.count == 1 {
            return self.buffers.first!
        } else {
            var result = ByteBufferAllocator().buffer(capacity: self.size)
            for var buffer in self.buffers {
                result.writeBuffer(&buffer)
            }
            return result
        }
    }
}
