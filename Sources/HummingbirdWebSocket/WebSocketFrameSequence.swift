//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2024 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOWebSocket

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

    var data: WebSocketDataFrame {
        .init(frame: self.collapsed)!
    }

    var opcode: WebSocketOpcode { self.frames.first!.opcode }

    var collapsed: WebSocketFrame {
        var frame = self.first
        frame.maskKey = nil
        frame.data = self.bytes
        frame.fin = true
        return frame
    }
}
