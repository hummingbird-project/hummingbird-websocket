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

import HummingbirdTesting
import Logging
import NIOSSL
import WSClient

extension TestClientProtocol {
    ///  Test WebSocket endpoint
    /// - Parameters:
    ///   - path: Endpoint path
    ///   - configuration: WebSocket client configuration
    ///   - logger: Logger
    ///   - handler: WebSocket handler
    /// - Returns: WebSocket close frame
    @discardableResult public func ws(
        _ path: String,
        configuration: WebSocketClientConfiguration = .init(),
        logger: Logger = Logger(label: "TestClient"),
        handler: @escaping WebSocketDataHandler<WebSocketClient.Context>
    ) async throws -> WebSocketCloseFrame? {
        guard let port else {
            preconditionFailure("Cannot test WebSockets without a live server. Use `.live` or `.ahc` to test WebSockets")
        }
        return try await WebSocketClient.connect(
            url: "ws://localhost:\(port)\(path)",
            configuration: configuration,
            logger: logger,
            handler: handler
        )
    }
}
