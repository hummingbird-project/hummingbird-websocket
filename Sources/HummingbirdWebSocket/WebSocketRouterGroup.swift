import Hummingbird

public struct HBWebSocketRouterGroup {
    let router: HBRouter
    let middlewares: HBMiddlewareGroup

    init(router: HBRouter) {
        self.router = router
        self.middlewares = .init()
    }

    /// Add middleware to RouterGroup
    public func add(middleware: HBMiddleware) -> HBWebSocketRouterGroup {
        self.middlewares.add(middleware)
        return self
    }

    /// Add path for closure returning type conforming to ResponseFutureEncodable
    @discardableResult public func on(
        _ path: String = "",
        shouldUpgrade: @escaping (HBRequest) -> EventLoopFuture<HTTPHeaders?>,
        onUpgrade: @escaping (HBRequest, HBWebSocket) -> Void
    ) -> Self {
        let responder = HBCallbackResponder { request in
            if request.webSocketTestShouldUpgrade != nil {
                return request.body.consumeBody(on: request.eventLoop).flatMap { buffer in
                    request.body = .byteBuffer(buffer)
                    return shouldUpgrade(request).map { headers in
                        HBResponse(status: .ok, headers: headers ?? [:])
                    }
                }
            } else if let webSocket = request.webSocket {
                return request.body.consumeBody(on: request.eventLoop).flatMapThrowing { buffer in
                    request.body = .byteBuffer(buffer)
                    onUpgrade(request, webSocket)
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

