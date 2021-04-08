//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOWebSocket

/// Enumeration holding WebSocket data
public enum WebSocketData: Equatable {
    case text(String)
    case binary(ByteBuffer)
}

/// Sequence of fragmented WebSocket frames.
struct WebSocketFrameSequence {
    enum SequenceType {
        case text
        case binary
    }

    var buffer: ByteBuffer
    var type: SequenceType

    init(type: SequenceType) {
        self.buffer = ByteBufferAllocator().buffer(capacity: 0)
        self.type = type
    }

    mutating func append(_ frame: WebSocketFrame) {
        var data = frame.unmaskedData
        self.buffer.writeBuffer(&data)
    }

    /// Combined frames
    var result: WebSocketData {
        switch self.type {
        case .text:
            return .text(String(buffer: self.buffer))
        case .binary:
            return .binary(self.buffer)
        }
    }
}
