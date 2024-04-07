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
public enum WebSocketMessage: Equatable, Sendable, CustomStringConvertible {
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

    public var description: String {
        switch self {
        case .text(let string):
            return "string(\"\(string)\")"
        case .binary(let buffer):
            return "binary(\(buffer.description))"
        }
    }
}
