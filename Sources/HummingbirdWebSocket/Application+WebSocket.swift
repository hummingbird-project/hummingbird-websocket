import Hummingbird
import HummingbirdWSCore

extension HBApplication {
    public struct WebSocket {
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
                    return responder.respond(to: request).map {
                        $0.headers
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
                start: .sync { self.responder = self.routerGroup.middlewares.constructResponder(finalResponder: application.router) },
                shutdown: .sync {}
            )
        }
        
        public func on(
            _ path: String = "",
            shouldUpgrade: @escaping (HBRequest) throws -> Void = { _ in },
            onUpgrade: @escaping (HBRequest, HBWebSocket) throws -> Void
        ) -> HBWebSocketRouterGroup {
            self.routerGroup.on(path, shouldUpgrade: shouldUpgrade, onUpgrade: onUpgrade)
        }
        
        public func add(middleware: HBMiddleware) -> HBWebSocketRouterGroup {
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
    
    public var ws: WebSocket { .init(application: self) }
}
