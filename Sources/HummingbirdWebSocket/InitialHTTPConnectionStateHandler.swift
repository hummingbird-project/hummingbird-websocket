//
// This source file is part of the Hummingbird server framework project
// Copyright (c) the Hummingbird authors
//
// See LICENSE.txt for license information
// SPDX-License-Identifier: Apache-2.0
//

import HTTPTypes
public import Logging
public import NIOCore
public import NIOHTTPTypes

/// Closes the connection if an upgrade does not happen or a quiesce event occurs
public final class InitialHTTPConnectionStateHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPRequestPart
    public typealias InboundOut = HTTPRequestPart
    public typealias OutboundIn = HTTPResponsePart
    public typealias OutboundOut = HTTPResponsePart

    let logger: Logger
    var idleTimeout: TimeAmount?
    var scheduledReaderTask: Scheduled<Void>?

    public init(idleTimeout: Duration? = nil, logger: Logger) {
        self.logger = logger
        self.idleTimeout = idleTimeout.map { TimeAmount($0) }
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        if self.scheduledReaderTask == nil, let idleTimeout {
            self.scheduledReaderTask = context.eventLoop.assumeIsolatedUnsafeUnchecked().scheduleTask(
                in: idleTimeout
            ) {
                context.close(mode: .all, promise: nil)
            }
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.scheduledReaderTask?.cancel()
    }

    public func channelActive(context: ChannelHandlerContext) {
        if self.scheduledReaderTask == nil, let idleTimeout {
            self.scheduledReaderTask = context.eventLoop.assumeIsolatedUnsafeUnchecked().scheduleTask(
                in: idleTimeout
            ) {
                context.close(promise: nil)
            }
        }
        context.fireChannelActive()
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelShouldQuiesceEvent:
            context.close(promise: nil)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}
