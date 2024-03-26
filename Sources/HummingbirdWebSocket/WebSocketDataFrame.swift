//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2023-2024 the Hummingbird authors
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

/// Enumeration holding WebSocket data
public enum WebSocketDataFrame: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
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

    public var webSocketFrame: WebSocketFrame {
        switch self {
        case .text(let string):
            return .init(fin: true, opcode: .text, data: ByteBuffer(string: string))
        case .binary(let buffer):
            return .init(fin: true, opcode: .binary, data: buffer)
        }
    }

    public var description: String {
        switch self {
        case .text(let string):
            return "string(\"\(string)\")"
        case .binary(let buffer):
            return "binary(\(buffer.description))"
        }
    }

    public var debugDescription: String {
        switch self {
        case .text(let string):
            return "string(\"\(string)\")"
        case .binary(let buffer):
            return "binary(\(buffer.debugDescription))"
        }
    }
}
