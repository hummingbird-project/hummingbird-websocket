import Hummingbird
import HummingbirdWSCore

extension HBApplication {
    /// WebSocket interface
    public struct WebSocket {
        /// Add WebSocket upgrade option
        public func addUpgrade() {
            application.server.addWebSocketUpgrade(
                shouldUpgrade: { channel, head in
                    let request = HBRequest(
                        head: head,
                        body: .byteBuffer(nil),
                        application: application,
                        eventLoop: channel.eventLoop,
                        allocator: channel.allocator
                    )
                    request.webSocketShouldUpgrade = true
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
                        eventLoop: ws.channel.eventLoop,
                        allocator: ws.channel.allocator
                    )
                    request.webSocket = ws
                    _ = responder.respond(to: request)
                }
            )
            routerGroup = .init(router: application.router)
            application.lifecycle.register(
                label: "WebSockets",
                start: .sync {
                    self.responder = self.application.middleware.constructResponder(finalResponder: application.router)
                },
                shutdown: .sync {}
            )
        }
        
        @discardableResult public func on(
            _ path: String = "",
            shouldUpgrade: @escaping (HBRequest) -> EventLoopFuture<HTTPHeaders?> = { $0.success(nil) },
            onUpgrade: @escaping (HBRequest, HBWebSocket) -> Void
        ) -> HBWebSocketRouterGroup {
            self.routerGroup.on(path, shouldUpgrade: shouldUpgrade, onUpgrade: onUpgrade)
        }
        
        @discardableResult public func add(middleware: HBMiddleware) -> HBWebSocketRouterGroup {
            self.routerGroup.add(middleware: middleware)
        }

        var routerGroup: HBWebSocketRouterGroup {
            get { application.extensions.get(\.ws.routerGroup) }
            nonmutating set { application.extensions.set(\.ws.routerGroup, value: newValue) }
        }
        
        var responder: HBResponder {
            get { application.extensions.get(\.ws.responder) }
            nonmutating set { application.extensions.set(\.ws.responder, value: newValue) }
        }

        let application: HBApplication
    }

    /// WebSocket interface
    public var ws: WebSocket { .init(application: self) }
}
