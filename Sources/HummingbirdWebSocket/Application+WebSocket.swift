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

import Hummingbird
import HummingbirdWSCore

extension HBApplication {
    /// WebSocket interface
    public struct WebSocket {
        /// Context used to create HBRequest
        struct WebSocketContext: HBRequestContext {
            var eventLoop: EventLoop
            var allocator: ByteBufferAllocator
            var remoteAddress: SocketAddress? { nil }
        }

        /// Add WebSocket upgrade option. This should be called before any other access to `HBApplication.ws` is performed
        public func addUpgrade() {
            self.application.server.addWebSocketUpgrade(
                shouldUpgrade: { channel, head in
                    let request = HBRequest(
                        head: head,
                        body: .byteBuffer(nil),
                        application: application,
                        context: WebSocketContext(eventLoop: channel.eventLoop, allocator: channel.allocator)
                    )
                    request.webSocketTestShouldUpgrade = true
                    return responder.respond(to: request).flatMapThrowing {
                        if $0.webSocketShouldUpgrade == true {
                            return $0.headers
                        }
                        throw HBHTTPError(.badRequest)
                    }
                },
                onUpgrade: { ws, head in
                    let request = HBRequest(
                        head: head,
                        body: .byteBuffer(nil),
                        application: application,
                        context: WebSocketContext(eventLoop: ws.channel.eventLoop, allocator: ws.channel.allocator)
                    )
                    request.webSocket = ws
                    _ = responder.respond(to: request)
                }
            )
            self.routerGroup = .init(router: self.application.router)
            self.application.lifecycle.register(
                label: "WebSockets",
                start: .sync {
                    self.responder = self.application.middleware.constructResponder(finalResponder: application.router)
                },
                shutdown: .sync {}
            )
        }

        /// Add WebSocket connection upgrade at given path
        /// - Parameters:
        ///   - path: URI path connection upgrade is available
        ///   - shouldUpgrade: Return whether upgrade should be allowed
        ///   - onUpgrade: Called on upgrade with reference to WebSocket
        @discardableResult public func on(
            _ path: String = "",
            shouldUpgrade: @escaping (HBRequest) -> EventLoopFuture<HTTPHeaders?> = { $0.success(nil) },
            onUpgrade: @escaping (HBRequest, HBWebSocket) -> Void
        ) -> HBWebSocketRouterGroup {
            self.routerGroup.on(path, shouldUpgrade: shouldUpgrade, onUpgrade: onUpgrade)
        }

        /// Add middleware to be run only for WebSocket HTTP upgrade requests
        @discardableResult public func add(middleware: HBMiddleware) -> HBWebSocketRouterGroup {
            self.routerGroup.add(middleware: middleware)
        }

        var routerGroup: HBWebSocketRouterGroup {
            get { self.application.extensions.get(\.ws.routerGroup) }
            nonmutating set { application.extensions.set(\.ws.routerGroup, value: newValue) }
        }

        var responder: HBResponder {
            get { self.application.extensions.get(\.ws.responder) }
            nonmutating set { application.extensions.set(\.ws.responder, value: newValue) }
        }

        let application: HBApplication
    }

    /// WebSocket interface
    public var ws: WebSocket { .init(application: self) }
}
