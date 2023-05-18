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

    /// Combined frames
    var combinedResult: WebSocketData {
        var result = ByteBufferAllocator().buffer(capacity: self.size)
        for var buffer in self.buffers {
            result.writeBuffer(&buffer)
        }
        // assume reserve1 flag indicates compressed
        if self.rsv1 {
            do {
                let decompressed = try result.decompress(with: .rawDeflate)
                let values = result.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8).self)
                guard let values = values, values.0 == 0, values.1 == 0, values.2 == 255, values.3 == 255 else {
                    return .text("")
                }
                result = decompressed
            } catch {
                return .text("")
            }
        }
        switch self.type {
        case .text:
            return .text(String(buffer: result))
        case .binary:
            return .binary(result)
        }
    }
}
