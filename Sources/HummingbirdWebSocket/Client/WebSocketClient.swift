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

import HummingbirdCore
import Logging
import NIOCore
import NIOPosix

struct HBWebSocketClientError: Error {
    private enum _Internal {
        case invalidURL
    }
    private let value: _Internal
    private init(_ value: _Internal) {
        self.value = value
    }

    static var invalidURL: Self { .init(.invalidURL) }
}

public struct HBWebSocketClient<Handler: HBWebSocketDataHandler> {
    let client: HBClient<WebSocketClientChannel<Handler>>

    /// Initialize client
    public init(
        handler: Handler,
        url: HBURL,
        maxFrameSize: Int = 1 << 14,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger
    ) throws {
        guard let host = url.host else { throw HBWebSocketClientError.invalidURL }
        let requiresTLS = url.scheme == .wss || url.scheme == .https
        let port = url.port ?? (requiresTLS ? 443 : 80)
        self.client = HBClient(
            childChannel: WebSocketClientChannel(handler: handler, maxFrameSize: maxFrameSize),
            address: .hostname(host, port: port),
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
    }

    /// Initialize client with callback
    public init(
        _ handlerCallback: @escaping HBWebSocketDataCallbackHandler.Callback,
        url: HBURL,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger
    ) throws where Handler == HBWebSocketDataCallbackHandler {
        let handler = HBWebSocketDataCallbackHandler(handlerCallback)
        try self.init(handler: handler, url: url, eventLoopGroup: eventLoopGroup, logger: logger)
    }

    public func run() async throws {
        try await self.client.run()
    }
}
