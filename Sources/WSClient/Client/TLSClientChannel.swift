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

import Logging
import NIOCore
import NIOSSL
import NIOWebSocket

/// Sets up client channel to use TLS before accessing base channel setup
@_documentation(visibility: internal)
public struct TLSClientChannel<BaseChannel: ClientConnectionChannel>: ClientConnectionChannel {
    public typealias Value = BaseChannel.Value
    public typealias Result = BaseChannel.Result

    ///  Initialize TLSChannel
    /// - Parameters:
    ///   - baseChannel: Base child channel wrap
    ///   - tlsConfiguration: TLS configuration
    public init(_ baseChannel: BaseChannel, tlsConfiguration: TLSConfiguration, serverHostname: String? = nil) throws {
        self.baseChannel = baseChannel
        self.sslContext = try NIOSSLContext(configuration: tlsConfiguration)
        self.serverHostname = serverHostname
    }

    /// Setup child channel with TLS and the base channel setup
    /// - Parameters:
    ///   - channel: Child channel
    ///   - logger: Logger used during setup
    /// - Returns: Object to process input/output on child channel
    @inlinable
    public func setup(channel: Channel, logger: Logger) -> EventLoopFuture<Value> {
        channel.eventLoop.makeCompletedFuture {
            let sslHandler = try NIOSSLClientHandler(context: self.sslContext, serverHostname: self.serverHostname)
            try channel.pipeline.syncOperations.addHandler(sslHandler)
        }.flatMap {
            self.baseChannel.setup(channel: channel, logger: logger)
        }
    }

    @inlinable
    /// handle messages being passed down the channel pipeline
    /// - Parameters:
    ///   - value: Object to process input/output on child channel
    ///   - logger: Logger to use while processing messages
    public func handle(value: BaseChannel.Value, logger: Logging.Logger) async throws -> Result {
        try await self.baseChannel.handle(value: value, logger: logger)
    }

    @usableFromInline
    let sslContext: NIOSSLContext
    @usableFromInline
    let serverHostname: String?
    @usableFromInline
    var baseChannel: BaseChannel
}
