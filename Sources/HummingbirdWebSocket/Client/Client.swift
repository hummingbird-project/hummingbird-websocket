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

import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import NIOPosix
import ServiceLifecycle

/// Address to bind server to
public enum HBServerAddress: Sendable {
    /// bind address define by host and port
    case hostname(_ host: String = "127.0.0.1", port: Int = 8080)
    /// bind address defined by unxi domain socket
    case unixDomainSocket(path: String)
}

/// HTTPServer child channel setup protocol
public protocol HBClientChildChannel: Sendable {
    associatedtype Value: Sendable

    /// Setup child channel
    /// - Parameters:
    ///   - channel: Child channel
    /// - Returns: Object to process input/output on child channel
    func setup(channel: Channel) -> EventLoopFuture<Value>

    /// handle messages being passed down the channel pipeline
    /// - Parameters:
    ///   - value: Object to process input/output on child channel
    ///   - logger: Logger to use while processing messages
    func handle(value: Value, logger: Logger) async throws
}

public struct HBClient<ChildChannel: HBClientChildChannel> {
    typealias ChannelResult = ChildChannel.Value
    /// Logger used by Server
    let logger: Logger
    let eventLoopGroup: EventLoopGroup
    let childChannel: ChildChannel
    let address: HBServerAddress

    /// Initialize Client
    public init(
        childChannel: ChildChannel,
        address: HBServerAddress,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger
    ) {
        self.childChannel = childChannel
        self.address = address
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
    }

    public func run() async throws {
        let channelResult = try await self.makeClient(
            childChannel: childChannel,
            address: address
        )
        try await childChannel.handle(value: channelResult, logger: self.logger)
    }

    /// Connect to server
    func makeClient(childChannel: ChildChannel, address: HBServerAddress) async throws -> ChannelResult {
        // get bootstrap
        let bootstrap: ClientBootstrapProtocol
        #if canImport(Network)
        if let tsBootstrap = self.createTSBootstrap() {
            bootstrap = tsBootstrap
        } else {
            #if os(iOS) || os(tvOS)
            self.logger.warning("Running BSD sockets on iOS or tvOS is not recommended. Please use NIOTSEventLoopGroup, to run with the Network framework")
            #endif
/*            if configuration.tlsOptions.options != nil {
                self.logger.warning("tlsOptions set in Configuration will not be applied to a BSD sockets server. Please use NIOTSEventLoopGroup, to run with the Network framework")
            }*/
            bootstrap = self.createSocketsBootstrap()
        }
        #else
        bootstrap = self.createSocketsBootstrap()
        #endif

        // connect
        switch address {
        case .hostname(let host, let port):
            return try await bootstrap
                .connect(host: host, port: port) { channel in
                    childChannel.setup(channel: channel)
                }
        case .unixDomainSocket(let path):
            return try await bootstrap
                .connect(unixDomainSocketPath: path) { channel in
                    childChannel.setup(channel: channel)
                }
        }
    }

    /// create a BSD sockets based bootstrap
    private func createSocketsBootstrap() -> some ClientBootstrapProtocol {
        return ClientBootstrap(group: self.eventLoopGroup)
    }

    #if canImport(Network)
    /// create a NIOTransportServices bootstrap using Network.framework
    private func createTSBootstrap() -> some ClientBootstrapProtocol? {
        guard let bootstrap = NIOTSClientBootstrap(validatingGroup: self.eventLoopGroup) else {
            return nil
        }

        /*if let tlsOptions = configuration.tlsOptions.options {
            return bootstrap.tlsOptions(tlsOptions)
        }*/
        return bootstrap
    }
    #endif
}

protocol ClientBootstrapProtocol {
    func connect<Output: Sendable>(
        host: String,
        port: Int,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output

    func connect<Output: Sendable>(
        unixDomainSocketPath: String,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output
}

extension ClientBootstrap: ClientBootstrapProtocol {}

/*
/// Protocol for bootstrap.
protocol ServerBootstrapProtocol {
    func bind<Output: Sendable>(
        host: String,
        port: Int,
        serverBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never>

    func bind<Output: Sendable>(
        unixDomainSocketPath: String,
        cleanupExistingSocketFile: Bool,
        serverBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never>
}

// Extend both `ServerBootstrap` and `NIOTSListenerBootstrap` to conform to `ServerBootstrapProtocol`
extension ServerBootstrap: ServerBootstrapProtocol {}

#if canImport(Network)
@available(macOS 10.14, iOS 12, tvOS 12, *)
extension NIOTSListenerBootstrap: ServerBootstrapProtocol {
    // need to be able to extend `NIOTSListenerBootstrap` to conform to `ServerBootstrapProtocol`
    // before we can use TransportServices
    func bind<Output: Sendable>(
        unixDomainSocketPath: String,
        cleanupExistingSocketFile: Bool,
        serverBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never> {
        preconditionFailure("Binding to a unixDomainSocketPath is currently not available")
    }
}
#endif
*/
