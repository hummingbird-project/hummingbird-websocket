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

/// Router Group for adding WebSocket connections to
public struct HBWebSocketRouterGroup {
    let router: HBRouterBuilder
    let middlewares: HBMiddlewareGroup

    init(router: HBRouterBuilder) {
        self.router = router
        self.middlewares = .init()
    }

    /// Add middleware to be applied to web socket upgrade requests
    public func add(middleware: HBMiddleware) -> HBWebSocketRouterGroup {
        self.middlewares.add(middleware)
        return self
    }

    /// Add path for websocket with shouldUpgrade and onUpgrade closures
    /// - Parameters:
    ///   - path: URI path that the websocket upgrade will proceed
    ///   - shouldUpgrade: Closure indicating whether we should upgrade or not. Return a failed `EventLoopFuture` for no.
    ///   - onUpgrade: Closure called with web socket when connection has been upgraded
    @discardableResult public func on(
        _ path: String = "",
        shouldUpgrade: @escaping (HBRequest) -> EventLoopFuture<HTTPHeaders?>,
        onUpgrade: @escaping (HBRequest, HBWebSocket) throws -> Void
    ) -> Self {
        let responder = HBCallbackResponder { request in
            var request = request
            if request.webSocketTestShouldUpgrade != nil {
                return request.body.consumeBody(on: request.eventLoop).flatMap { buffer in
                    request.body = .byteBuffer(buffer)
                    return shouldUpgrade(request).map { headers in
                        return HBResponse(status: .ok, headers: headers ?? [:])
                    }
                }
            } else if let webSocket = request.webSocket {
                return request.body.consumeBody(on: request.eventLoop).flatMapThrowing { buffer in
                    request.body = .byteBuffer(buffer)
                    try onUpgrade(request, webSocket)
                    return HBResponse(status: .ok)
                }
            } else {
                return request.failure(.upgradeRequired)
            }
        }
        self.router.add(path, method: .GET, responder: self.middlewares.constructResponder(finalResponder: responder))
        return self
    }
}
