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

    init?(frame: WebSocketFrame) {
        switch frame.opcode {
        case .text:
            self = .text(String(buffer: frame.unmaskedData))
        case .binary:
            self = .binary(frame.unmaskedData)
        default:
            return nil
        }
    }
}

/// Sequence of fragmented WebSocket frames.
struct WebSocketFrameSequence {
    var frames: [WebSocketFrame]
    var size: Int
    var first: WebSocketFrame { self.frames[0] }

    init(frame: WebSocketFrame) {
        self.frames = [frame]
        self.size = 0
    }

    mutating func append(_ frame: WebSocketFrame) {
        assert(frame.opcode == self.first.opcode)
        self.frames.append(frame)
        self.size += frame.data.readableBytes
    }

    var bytes: ByteBuffer {
        if self.frames.count == 1 {
            return self.frames[0].unmaskedData
        } else {
            var result = ByteBufferAllocator().buffer(capacity: self.size)
            for frame in self.frames {
                var data = frame.unmaskedData
                result.writeBuffer(&data)
            }
            return result
        }
    }

    var collapsed: WebSocketFrame {
        var frame = self.first
        frame.maskKey = nil
        frame.data = self.bytes
        return frame
    }
}
