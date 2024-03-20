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

import HTTPTypes
import HummingbirdCore
import HummingbirdTLS
import Logging
import NIOCore
import NIOPosix
import NIOTransportServices
import ServiceLifecycle

/// WebSocket client
///
/// Connect to HTTP server with WebSocket upgrade available.
///
/// Supports TLS via both NIOSSL and Network framework.
///
/// Initialize the WebSocketClient with your handler and then call ``WebSocketClient/run()``
/// to connect. The handler is provider with an `inbound` stream of WebSocket packets coming
/// from the server and an `outbound` writer that can be used to write packets to the server.
/// ```swift
/// let webSocket = WebSocketClient(url: "ws://test.org/ws", logger: logger) { inbound, outbound, context in
///     for try await packet in inbound {
///         if case .text(let string) = packet {
///             try await outbound.write(.text(string))
///         }
///     }
/// }
/// ```
public struct WebSocketClient {
    enum MultiPlatformTLSConfiguration: Sendable {
        case niossl(TLSConfiguration)
        #if canImport(Network)
        case ts(TSTLSOptions)
        #endif
    }

    /// WebSocket URL
    let url: URI
    /// WebSocket data handler
    let handler: WebSocketDataHandler<WebSocketContext>
    /// configuration
    let configuration: WebSocketClientConfiguration
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
        url: URI,
        configuration: WebSocketClientConfiguration = .init(),
        tlsConfiguration: TLSConfiguration? = nil,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger,
        handler: @escaping WebSocketDataHandler<WebSocketContext>
    ) throws {
        self.url = url
        self.handler = handler
        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.tlsConfiguration = tlsConfiguration.map { .niossl($0) }
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
        url: URI,
        configuration: WebSocketClientConfiguration = .init(),
        transportServicesTLSOptions: TSTLSOptions,
        eventLoopGroup: NIOTSEventLoopGroup = NIOTSEventLoopGroup.singleton,
        logger: Logger,
        handler: @escaping WebSocketDataHandler<WebSocketContext>
    ) throws {
        self.url = url
        self.handler = handler
        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.tlsConfiguration = .ts(transportServicesTLSOptions)
    }
    #endif

    ///  Connect and run handler
    public func run() async throws {
        guard let host = url.host else { throw WebSocketClientError.invalidURL }
        let requiresTLS = self.url.scheme == .wss || self.url.scheme == .https
        let port = self.url.port ?? (requiresTLS ? 443 : 80)
        // url path must include query values as well
        let urlPath = self.url.path + (self.url.query.map { "?\($0)" } ?? "")
        if requiresTLS {
            switch self.tlsConfiguration {
            case .niossl(let tlsConfiguration):
                let client = try ClientConnection(
                    TLSClientChannel(
                        WebSocketClientChannel(handler: handler, url: urlPath, configuration: self.configuration),
                        tlsConfiguration: tlsConfiguration
                    ),
                    address: .hostname(host, port: port),
                    eventLoopGroup: self.eventLoopGroup,
                    logger: self.logger
                )
                try await client.run()

            #if canImport(Network)
            case .ts(let tlsOptions):
                let client = try ClientConnection(
                    WebSocketClientChannel(handler: handler, url: urlPath, configuration: self.configuration),
                    address: .hostname(host, port: port),
                    transportServicesTLSOptions: tlsOptions,
                    eventLoopGroup: self.eventLoopGroup,
                    logger: self.logger
                )
                try await client.run()

            #endif
            case .none:
                let client = try ClientConnection(
                    TLSClientChannel(
                        WebSocketClientChannel(
                            handler: handler,
                            url: urlPath,
                            configuration: self.configuration
                        ),
                        tlsConfiguration: TLSConfiguration.makeClientConfiguration()
                    ),
                    address: .hostname(host, port: port),
                    eventLoopGroup: self.eventLoopGroup,
                    logger: self.logger
                )
                try await client.run()
            }
        } else {
            let client = ClientConnection(
                WebSocketClientChannel(
                    handler: handler,
                    url: urlPath,
                    configuration: self.configuration
                ),
                address: .hostname(host, port: port),
                eventLoopGroup: self.eventLoopGroup,
                logger: self.logger
            )
            try await client.run()
        }
    }
}

extension WebSocketClient {
    /// Create websocket client, connect and handle connection
    ///
    /// - Parametes:
    ///   - url: URL of websocket
    ///   - tlsConfiguration: TLS configuration
    ///   - maxFrameSize: Max frame size for a single packet
    ///   - eventLoopGroup: EventLoopGroup to run WebSocket client on
    ///   - logger: Logger
    ///   - process: Closure handling webSocket
    public static func connect(
        url: URI,
        configuration: WebSocketClientConfiguration = .init(),
        tlsConfiguration: TLSConfiguration? = nil,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger,
        handler: @escaping WebSocketDataHandler<WebSocketContext>
    ) async throws {
        let ws = try self.init(
            url: url,
            configuration: configuration,
            tlsConfiguration: tlsConfiguration,
            eventLoopGroup: eventLoopGroup,
            logger: logger,
            handler: handler
        )
        try await ws.run()
    }

    #if canImport(Network)
    /// Create websocket client, connect and handle connection
    ///
    /// - Parametes:
    ///   - url: URL of websocket
    ///   - transportServicesTLSOptions: TLS options for NIOTransportServices
    ///   - maxFrameSize: Max frame size for a single packet
    ///   - eventLoopGroup: EventLoopGroup to run WebSocket client on
    ///   - logger: Logger
    ///   - process: WebSocket data handler
    public static func connect(
        url: URI,
        configuration: WebSocketClientConfiguration = .init(),
        transportServicesTLSOptions: TSTLSOptions,
        eventLoopGroup: NIOTSEventLoopGroup = NIOTSEventLoopGroup.singleton,
        logger: Logger,
        handler: @escaping WebSocketDataHandler<WebSocketContext>
    ) async throws {
        let ws = try self.init(
            url: url,
            configuration: configuration,
            transportServicesTLSOptions: transportServicesTLSOptions,
            eventLoopGroup: eventLoopGroup,
            logger: logger,
            handler: handler
        )
        try await ws.run()
    }
    #endif
}

/// conform to Service
extension WebSocketClient: Service {}
