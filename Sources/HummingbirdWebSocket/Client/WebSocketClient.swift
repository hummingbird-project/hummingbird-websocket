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
import HummingbirdTLS
import Logging
import NIOCore
import NIOPosix

/// WebSocket client
///
/// Connect to HTTP server with WebSocket upgrade available.
///
/// Supports TLS via both NIOSSL and Network framework.
///
/// Initialize the HBWebSocketClient with your handler and then call ``HBWebSocketClient/run``
/// to connect. The handler is provider with an `inbound` stream of WebSocket packets coming
/// from the server and an `outbound` writer that can be used to write packets to the server.
/// ```swift
/// let webSocket = HBWebSocketClient(url: "ws://test.org/ws", logger: logger) { inbound, outbound, context in
///     for try await packet in inbound {
///         if case .text(let string) = packet {
///             try await outbound.write(.text(string))
///         }
///     }
/// }
/// ```
public struct HBWebSocketClient<Handler: HBWebSocketDataHandler> {
    public struct Error: Swift.Error, Equatable {
        private enum _Internal: Equatable {
            case invalidURL
        }

        private let value: _Internal
        private init(_ value: _Internal) {
            self.value = value
        }

        public static var invalidURL: Self { .init(.invalidURL) }
    }

    enum MultiPlatformTLSConfiguration {
        case niossl(TLSConfiguration)
        #if canImport(Network)
        case ts(TSTLSOptions)
        #endif
    }

    /// WebSocket URL
    let url: HBURL
    /// WebSocket data handler
    let handler: Handler
    /// Max frame size for a single packet
    let maxFrameSize: Int
    /// EventLoopGroup to use
    let eventLoopGroup: EventLoopGroup
    /// Logger
    let logger: Logger
    /// TLS configuration
    let tlsConfiguration: MultiPlatformTLSConfiguration?

    /// Initialize websocket client
    ///
    /// - Parametes:
    ///   - url: URL of websocket
    ///   - tlsConfiguration: TLS configuration
    ///   - handler: WebSocket data handler
    ///   - maxFrameSize: Max frame size for a single packet
    ///   - eventLoopGroup: EventLoopGroup to run WebSocket client on
    ///   - logger: Logger
    public init(
        url: HBURL,
        tlsConfiguration: TLSConfiguration? = nil,
        handler: Handler,
        maxFrameSize: Int = 1 << 14,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger
    ) throws {
        self.url = url
        self.handler = handler
        self.maxFrameSize = maxFrameSize
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.tlsConfiguration = tlsConfiguration.map { .niossl($0) }
    }

    /// Initialize websocket client with callback
    ///
    /// - Parametes:
    ///   - url: URL of websocket
    ///   - tlsConfiguration: TLS configuration
    ///   - maxFrameSize: Max frame size for a single packet
    ///   - eventLoopGroup: EventLoopGroup to run WebSocket client on
    ///   - logger: Logger
    ///   - handlerCallback: Closure handling webSocket
    public init(
        url: HBURL,
        tlsConfiguration: TLSConfiguration? = nil,
        maxFrameSize: Int = 1 << 14,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger,
        handlerCallback: @escaping HBWebSocketDataCallbackHandler.Callback
    ) throws where Handler == HBWebSocketDataCallbackHandler {
        let handler = HBWebSocketDataCallbackHandler(handlerCallback)
        try self.init(
            url: url,
            tlsConfiguration: tlsConfiguration,
            handler: handler,
            maxFrameSize: maxFrameSize,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
    }

    #if canImport(Network)
    /// Initialize websocket client
    ///
    /// - Parametes:
    ///   - url: URL of websocket
    ///   - transportServicesTLSOptions: TLS options for NIOTransportServices
    ///   - handler: WebSocket data handler
    ///   - maxFrameSize: Max frame size for a single packet
    ///   - eventLoopGroup: EventLoopGroup to run WebSocket client on
    ///   - logger: Logger
    public init(
        url: HBURL,
        transportServicesTLSOptions: TSTLSOptions,
        handler: Handler,
        maxFrameSize: Int = 1 << 14,
        eventLoopGroup: NIOTSEventLoopGroup = NIOTSEventLoopGroup.singleton,
        logger: Logger
    ) throws {
        self.url = url
        self.handler = handler
        self.maxFrameSize = maxFrameSize
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.tlsConfiguration = .ts(transportServicesTLSOptions)
    }

    /// Initialize websocket client with callback
    ///
    /// - Parametes:
    ///   - url: URL of websocket
    ///   - transportServicesTLSOptions: TLS options for NIOTransportServices
    ///   - maxFrameSize: Max frame size for a single packet
    ///   - eventLoopGroup: EventLoopGroup to run WebSocket client on
    ///   - logger: Logger
    ///   - handlerCallback: Closure handling webSocket
    public init(
        url: HBURL,
        transportServicesTLSOptions: TSTLSOptions,
        maxFrameSize: Int = 1 << 14,
        eventLoopGroup: NIOTSEventLoopGroup = NIOTSEventLoopGroup.singleton,
        logger: Logger,
        handlerCallback: @escaping HBWebSocketDataCallbackHandler.Callback
    ) throws where Handler == HBWebSocketDataCallbackHandler {
        let handler = HBWebSocketDataCallbackHandler(handlerCallback)
        try self.init(
            url: url,
            transportServicesTLSOptions: transportServicesTLSOptions,
            handler: handler,
            maxFrameSize: maxFrameSize,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
    }
    #endif

    ///  Connect and run handler
    public func run() async throws {
        guard let host = url.host else { throw Error.invalidURL }
        let requiresTLS = self.url.scheme == .wss || self.url.scheme == .https
        let port = self.url.port ?? (requiresTLS ? 443 : 80)
        if requiresTLS {
            switch self.tlsConfiguration {
            case .niossl(let tlsConfiguration):
                let client = try HBClient(
                    TLSClientChannel(
                        WebSocketClientChannel(handler: handler, maxFrameSize: maxFrameSize),
                        tlsConfiguration: tlsConfiguration
                    ),
                    address: .hostname(host, port: port),
                    eventLoopGroup: eventLoopGroup,
                    logger: logger
                )
                try await client.run()

            #if canImport(Network)
            case .ts(let tlsOptions):
                let client = HBClient(
                    WebSocketClientChannel(handler: handler, maxFrameSize: maxFrameSize),
                    address: .hostname(host, port: port),
                    transportServicesTLSOptions: tlsOptions,
                    eventLoopGroup: eventLoopGroup,
                    logger: logger
                )
                try await client.run()

            #endif
            case .none:
                let client = try HBClient(
                    TLSClientChannel(
                        WebSocketClientChannel(handler: handler, maxFrameSize: maxFrameSize),
                        tlsConfiguration: TLSConfiguration.makeClientConfiguration()
                    ),
                    address: .hostname(host, port: port),
                    eventLoopGroup: self.eventLoopGroup,
                    logger: self.logger
                )
                try await client.run()
            }
        } else {
            let client = HBClient(
                WebSocketClientChannel(handler: handler, maxFrameSize: maxFrameSize),
                address: .hostname(host, port: port),
                eventLoopGroup: eventLoopGroup,
                logger: logger
            )
            try await client.run()
        }
    }
}
