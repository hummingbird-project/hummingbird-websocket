import HTTPTypes
import Hummingbird
import HummingbirdWebSocket

let router = Router()
router.get { _, _ in
    "Hello"
}

router.middlewares.add(FileMiddleware("Snippets/public"))
let app = Application(
    router: router,
    server: .webSocketUpgrade { _, head, _ in
        if head.path == "/ws" {
            return .upgrade(.init()) { inbound, outbound, _ in
                for try await packet in inbound {
                    if case .text("disconnect") = packet {
                        break
                    }
                    try await outbound.write(.custom(packet.webSocketFrame))
                }
            }
        } else {
            return .dontUpgrade
        }
    }
)
try await app.runService()
