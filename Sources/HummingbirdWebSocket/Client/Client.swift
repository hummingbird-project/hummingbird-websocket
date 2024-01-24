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
    let address: HBBindAddress

    /// Initialize Server
    /// - Parameters:
    ///   - group: EventLoopGroup server uses
    ///   - configuration: Configuration for server
    public init(
        childChannel: ChildChannel,
        address: HBBindAddress,
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
    func makeClient(childChannel: ChildChannel, address: HBBindAddress) async throws -> ChannelResult {
        guard case .hostname(let host, let port) = address else { preconditionFailure("Unix address not supported")}
        return try await ClientBootstrap(group: self.eventLoopGroup)
            .connect(host: host, port: port) { channel in
                childChannel.setup(channel: channel)
            }
    }
/*
    /// create a BSD sockets based bootstrap
    private func createSocketsBootstrap(
        configuration: HBServerConfiguration
    ) -> ServerBootstrap {
        return ServerBootstrap(group: self.eventLoopGroup)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: numericCast(configuration.backlog))
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: configuration.reuseAddress ? 1 : 0)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: configuration.reuseAddress ? 1 : 0)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    #if canImport(Network)
    /// create a NIOTransportServices bootstrap using Network.framework
    @available(macOS 10.14, iOS 12, tvOS 12, *)
    private func createTSBootstrap(
        configuration: HBServerConfiguration
    ) -> NIOTSListenerBootstrap? {
        guard let bootstrap = NIOTSListenerBootstrap(validatingGroup: self.eventLoopGroup)?
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: configuration.reuseAddress ? 1 : 0)
            // Set the handlers that are applied to the accepted Channels
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: configuration.reuseAddress ? 1 : 0)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        else {
            return nil
        }

        if let tlsOptions = configuration.tlsOptions.options {
            return bootstrap.tlsOptions(tlsOptions)
        }
        return bootstrap
    }
    #endif*/
}
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
