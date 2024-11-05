//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2024 the Hummingbird authors
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

struct WebSocketStateMachine {
    var state: State

    enum CloseResult {
        case sendClose
        case doNothing
    }

    mutating func close() -> CloseResult {
        switch self.state {
        case .open:
            self.state = .closing
            return .sendClose
        case .closing:
            return .doNothing
        case .closed:
            return .doNothing
        }
    }

    enum ReceivedCloseResult {
        case sendClose(WebSocketErrorCode)
        case doNothing
    }

    mutating func receivedClose(frame: WebSocketFrame) -> ReceivedCloseResult {
        // we received a connection close.
        // send a close back if it hasn't already been send and exit
        var data = frame.unmaskedData
        let dataSize = data.readableBytes
        // read close code and close reason
        let closeCode = data.readWebSocketErrorCode()
        let reason = data.readableBytes > 0
            ? data.readString(length: data.readableBytes)
            : nil

        switch self.state {
        case .open:
            self.state = .closed(closeCode.map { .init(closeCode: $0, reason: reason) })
            let code: WebSocketErrorCode = if dataSize == 0 || closeCode != nil {
                // codes 3000 - 3999 are reserved for use by libraries, frameworks, and applications
                // so are considered valid
                if case .unknown(let code) = closeCode, code < 3000 || code > 3999 {
                    .protocolError
                } else {
                    .normalClosure
                }
            } else {
                .protocolError
            }
            return .sendClose(code)
        case .closing:
            self.state = .closed(closeCode.map { .init(closeCode: $0, reason: reason) })
            return .doNothing
        case .closed:
            return .doNothing
        }
    }
}

extension WebSocketStateMachine {
    enum State {
        case open
        case closing
        case closed(WebSocketCloseFrame?)
    }
}
