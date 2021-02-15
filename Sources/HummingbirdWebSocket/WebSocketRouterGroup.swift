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
        shouldUpgrade: @escaping (HBRequest) throws -> Void,
        onUpgrade: @escaping (HBRequest, HBWebSocket) throws -> Void
    ) -> Self {
        let responder = CallbackResponder { request in
            guard let webSocket = request.webSocket else {
                return request.body.consumeBody(on: request.eventLoop).flatMapThrowing { buffer in
                    request.body = .byteBuffer(buffer)
                    do {
                        try shouldUpgrade(request)
                        return HBResponse(status: .upgradeRequired)
                    } catch {
                        throw HBHTTPError(.upgradeRequired)
                    }
                }
            }
            return request.body.consumeBody(on: request.eventLoop).flatMapThrowing { buffer in
                request.body = .byteBuffer(buffer)
                try onUpgrade(request, webSocket)
                return HBResponse(status: .ok)
            }
        }
        self.router.add(path, method: .GET, responder: self.middlewares.constructResponder(finalResponder: responder))
        return self
    }
}

