import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging

var logger = Logger(label: "Echo")
logger.logLevel = .trace
let router = Router(context: BasicWebSocketRequestContext.self)
router.middlewares.add(FileMiddleware("Snippets/public"))
router.get { _, _ in
    "Hello"
}

router.ws("/ws") { inbound, outbound, _ in
    for try await packet in inbound {
        if case .text("disconnect") = packet {
            break
        }
        try await outbound.write(.custom(packet.webSocketFrame))
    }
}

let app = Application(
    router: router,
    server: .webSocketUpgrade(webSocketRouter: router),
    logger: logger
)
try await app.runService()
