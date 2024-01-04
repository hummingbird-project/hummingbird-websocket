import Hummingbird
import HummingbirdFoundation
import HummingbirdWebSocket
import NIOHTTP1

let router = HBRouter()
router.get { _, _ in
    "Hello"
}

router.middlewares.add(HBFileMiddleware("Snippets/public"))
let app = HBApplication(
    responder: router.buildResponder(),
    server: .httpAndWebSocket { channel, head in
        if head.uri == "ws" {
            return .upgrade(HTTPHeaders()) { inbound, outbound, _ in
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
