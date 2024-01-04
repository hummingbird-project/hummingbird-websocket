import Hummingbird
import HummingbirdFoundation
import HummingbirdWebSocket

let router = HBRouter()
router.get { _,_ in
    "Hello"
}
router.middlewares.add(HBFileMiddleware("Snippets/public"))
let app = HBApplication(
    responder: router.buildResponder(), 
    server: .httpAndWebSocket { _,_ in
        let handler = HBWebSocketDataCallbackHandler { inbound, outbound, context in
            for try await packet in inbound {
                if case .text("disconnect") = packet {
                    break
                }
                try await outbound.write(.custom(packet.webSocketFrame))
            }
        }
        return .upgrade(.init(), handler)
    }
)
try await app.runService()