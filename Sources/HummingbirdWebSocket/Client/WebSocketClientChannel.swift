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
import NIOHTTP1
import NIOWebSocket

public struct WebSocketClientChannel<Handler: HBWebSocketDataHandler>: HBClientChannel {
    public enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case notUpgraded
    }
    public typealias Value = EventLoopFuture<UpgradeResult>

    let handler: Handler
    let maxFrameSize: Int
    
    init(handler: Handler, maxFrameSize: Int = 1 << 14) {
        self.handler = handler
        self.maxFrameSize = maxFrameSize
    }

    public func setup(channel: any Channel, logger: Logger) -> NIOCore.EventLoopFuture<Value> {
        channel.eventLoop.makeCompletedFuture {
            let upgrader = NIOTypedWebSocketClientUpgrader<UpgradeResult>(
                maxFrameSize: maxFrameSize,
                upgradePipelineHandler: { (channel, _) in
                    channel.eventLoop.makeCompletedFuture {
                        let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                        return UpgradeResult.websocket(asyncChannel)
                    }
                }
            )

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "0")

            let requestHead = HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: "/",
                headers: headers
            )

            let clientUpgradeConfiguration = NIOTypedHTTPClientUpgradeConfiguration(
                upgradeRequestHead: requestHead,
                upgraders: [upgrader],
                notUpgradingCompletionHandler: { channel in
                    /*channel.close().map {
                        UpgradeResult.notUpgraded
                    }*/
                    channel.eventLoop.makeCompletedFuture {
                        return UpgradeResult.notUpgraded
                    }
                }
            )

            let negotiationResultFuture = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                configuration: .init(upgradeConfiguration: clientUpgradeConfiguration)
            )

            return negotiationResultFuture
        }
    }

    public func handle(value: Value, logger: Logging.Logger) async throws {
        switch try await value.get() {
        case .websocket(let websocketChannel):
            let webSocket = HBWebSocketHandler(asyncChannel: websocketChannel, type: .client)
            let context = handler.alreadySetupContext ?? .init(logger: logger, allocator: websocketChannel.channel.allocator)
            await webSocket.handle(handler: handler, context: context)
        case .notUpgraded:
            // The upgrade to websocket did not succeed. We are just exiting in this case.
            print("Upgrade declined")
        }
    }
}