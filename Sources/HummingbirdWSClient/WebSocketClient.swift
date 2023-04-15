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

import ExtrasBase64
import Hummingbird
import HummingbirdWSCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

/// Manages WebSocket client creation
public enum HBWebSocketClient {
    /// Connect to WebSocket
    /// - Parameters:
    ///   - url: URL of websocket
    ///   - headers: Additional headers to send in initial HTTP request
    ///   - configuration: Configuration of connection
    ///   - eventLoop: eventLoop to run connection on
    ///   - readCallback: Setup read callback immediately. Use this if you need to be sure you don't miss any reads
    ///         between the WebSocket connection being setup and the EventLoopFuture completing
    /// - Returns: EventLoopFuture which will be fulfilled with `HBWebSocket` once connection is made
    public static func connect(
        url: HBURL,
        headers: HTTPHeaders = [:],
        configuration: Configuration,
        on eventLoop: EventLoop,
        readCallback: ((WebSocketData, HBWebSocket) -> Void)? = nil
    ) -> EventLoopFuture<HBWebSocket> {
        let wsPromise = eventLoop.makePromise(of: HBWebSocket.self)
        do {
            let url = try SplitURL(url: url)
            let bootstrap = try createBootstrap(url: url, configuration: configuration, on: eventLoop)
            bootstrap
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    return Self.setupChannelForWebsockets(
                        url: url,
                        headers: headers,
                        configuration: configuration,
                        channel: channel,
                        wsPromise: wsPromise,
                        on: eventLoop,
                        readCallback: readCallback
                    )
                }
                .connect(host: url.host, port: url.port)
                .cascadeFailure(to: wsPromise)

        } catch {
            wsPromise.fail(error)
        }
        return wsPromise.futureResult
    }

    /// create bootstrap
    static func createBootstrap(url: SplitURL, configuration: Configuration, on eventLoop: EventLoop) throws -> NIOClientTCPBootstrap {
        if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
            let sslContext = try NIOSSLContext(configuration: configuration.tlsConfiguration)
            let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: url.host)
            let bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
            if url.tlsRequired {
                bootstrap.enableTLS()
            }
            return bootstrap
        }
        preconditionFailure("Failed to create web socket bootstrap")
    }

    /// setup for channel for websocket. Create initial HTTP request and include upgrade for when it is successful
    static func setupChannelForWebsockets(
        url: SplitURL,
        headers: HTTPHeaders,
        configuration: Configuration,
        channel: Channel,
        wsPromise: EventLoopPromise<HBWebSocket>,
        on eventLoop: EventLoop,
        readCallback: ((WebSocketData, HBWebSocket) -> Void)? = nil
    ) -> EventLoopFuture<Void> {
        let upgradePromise = eventLoop.makePromise(of: Void.self)
        upgradePromise.futureResult.cascadeFailure(to: wsPromise)

        // initial HTTP request handler, before upgrade
        let httpHandler: WebSocketInitialRequestHandler
        do {
            httpHandler = try WebSocketInitialRequestHandler(
                url: url,
                headers: headers,
                upgradePromise: upgradePromise
            )
        } catch {
            upgradePromise.fail(Error.invalidURL)
            return upgradePromise.futureResult
        }

        // create random key for request key
        let requestKey = (0..<16).map { _ in UInt8.random(in: .min ..< .max) }
        let base64Key = String(base64Encoding: requestKey, options: [])
        let websocketUpgrader = NIOWebSocketClientUpgrader(
            requestKey: base64Key,
            maxFrameSize: configuration.maxFrameSize
        ) { channel, _ in
            let webSocket = HBWebSocket(channel: channel, type: .client)
            if let readCallback = readCallback {
                webSocket.onRead(readCallback)
            }
            return channel.pipeline.addHandler(WebSocketHandler(webSocket: webSocket)).map { _ -> Void in
                wsPromise.succeed(webSocket)
                upgradePromise.succeed(())
            }
        }

        let config: NIOHTTPClientUpgradeConfiguration = (
            upgraders: [websocketUpgrader],
            completionHandler: { _ in
                channel.pipeline.removeHandler(httpHandler, promise: nil)
            }
        )

        // add HTTP handler with web socket upgrade
        return channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, withClientUpgrade: config).flatMap {
            channel.pipeline.addHandler(httpHandler)
        }
    }

    /// Possible Errors returned by websocket connection
    public enum Error: Swift.Error {
        case invalidURL
        case websocketUpgradeFailed
    }

    /// WebSocket connection configuration
    public struct Configuration: Sendable {
        /// TLS setup
        let tlsConfiguration: TLSConfiguration

        /// Maximum size for a single frame
        let maxFrameSize: Int

        /// initialize Configuration
        public init(
            maxFrameSize: Int = 1 << 14,
            tlsConfiguration: TLSConfiguration = TLSConfiguration.makeClientConfiguration()
        ) {
            self.maxFrameSize = maxFrameSize
            self.tlsConfiguration = tlsConfiguration
        }
    }

    /// Processed URL split into sections we need for connection
    struct SplitURL {
        let host: String
        let pathQuery: String
        let port: Int
        let tlsRequired: Bool

        init(url: HBURL) throws {
            guard let host = url.host else { throw HBWebSocketClient.Error.invalidURL }
            self.host = host
            if let port = url.port {
                self.port = port
            } else {
                if url.scheme == .https || url.scheme == .wss {
                    self.port = 443
                } else {
                    self.port = 80
                }
            }
            self.tlsRequired = url.scheme == .https || url.scheme == .wss ? true : false
            self.pathQuery = url.path + (url.query.map { "?\($0)" } ?? "")
        }

        /// return "Host" header value. Only include port if it is different from the default port for the request
        var hostHeader: String {
            if (self.tlsRequired && self.port != 443) || (!self.tlsRequired && self.port != 80) {
                return "\(self.host):\(self.port)"
            }
            return self.host
        }
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension HBWebSocketClient {
    /// Connect to WebSocket
    /// - Parameters:
    ///   - url: URL of websocket
    ///   - headers: Additional headers to send in initial HTTP request
    ///   - configuration: Configuration of connection
    ///   - eventLoop: eventLoop to run connection on
    ///   - readCallback: Setup read callback immediately. Use this if you need to be sure you don't miss any reads
    ///         between the WebSocket connection being setup and the EventLoopFuture completing
    public static func connect(
        url: HBURL,
        headers: HTTPHeaders = [:],
        configuration: Configuration,
        on eventLoop: EventLoop,
        readCallback: ((WebSocketData, HBWebSocket) -> Void)? = nil
    ) async throws -> HBWebSocket {
        return try await self.connect(
            url: url,
            headers: headers,
            configuration: configuration,
            on: eventLoop,
            readCallback: readCallback
        ).get()
    }
}
