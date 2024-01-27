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
    enum MultiPlatformTLSConfiguration {
        case niossl(TLSConfiguration)
        #if canImport(Network)
        case ts(TSTLSOptions)
        #endif
    }
    let url: HBURL
    let handler: Handler
    let maxFrameSize: Int
    let eventLoopGroup: EventLoopGroup
    let logger: Logger
    let tlsConfiguration: MultiPlatformTLSConfiguration?

    /// Initialize client
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

    /// Initialize client with callback
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
    /// Initialize client
    public init(
        url: HBURL,
        transportServicesTLSOptions: TSTLSOptions,
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
        self.tlsConfiguration = .ts(transportServicesTLSOptions)
    }

    /// Initialize client with callback
    public init(
        url: HBURL,
        transportServicesTLSOptions: TSTLSOptions,
        maxFrameSize: Int = 1 << 14,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
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

    public func run() async throws {
        guard let host = url.host else { throw HBWebSocketClientError.invalidURL }
        let requiresTLS = url.scheme == .wss || url.scheme == .https
        let port = url.port ?? (requiresTLS ? 443 : 80)
        if requiresTLS {
            switch self.tlsConfiguration {
            case .niossl(let tlsConfiguration):
                let client = HBClient(
                    try TLSClientChannel(
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
                let client = HBClient(
                    try TLSClientChannel(
                        WebSocketClientChannel(handler: handler, maxFrameSize: maxFrameSize), 
                        tlsConfiguration: TLSConfiguration.makeClientConfiguration()
                    ),
                    address: .hostname(host, port: port),
                    eventLoopGroup: eventLoopGroup,
                    logger: logger
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
