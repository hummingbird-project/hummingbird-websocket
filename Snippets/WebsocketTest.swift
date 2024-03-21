import HTTPTypes
import Hummingbird
import HummingbirdWebSocket

let router = Router(context: BasicWebSocketRequestContext.self)
router.middlewares.add(FileMiddleware("Snippets/public"))
router.get { _, _ in
    "Hello"
}

router.ws("/ws") { ws, _ in
    for try await packet in ws.inbound {
        if case .text("disconnect") = packet {
            break
        }
        try await ws.outbound.write(.custom(packet.webSocketFrame))
    }
}

let app = Application(
    router: router,
    server: .webSocketUpgrade(webSocketRouter: router)
)
try await app.runService()
