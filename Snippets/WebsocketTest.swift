import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOWebSocket
import WSCompression

var logger = Logger(label: "Echo")
logger.logLevel = .trace
let router = Router(context: BasicWebSocketRequestContext.self)
router.middlewares.add(FileMiddleware("Snippets/public"))
router.get { _, _ in
    "Hello"
}

router.ws("/ws") { inbound, outbound, _ in
    try await outbound.write(.text("Hello"))
    for try await frame in inbound {
        if frame.opcode == .text, String(buffer: frame.data) == "disconnect", frame.fin == true {
            break
        }
        let opcode: WebSocketOpcode =
            switch frame.opcode {
            case .text: .text
            case .binary: .binary
            case .continuation: .continuation
            }
        let frame = WebSocketFrame(
            fin: frame.fin,
            opcode: opcode,
            data: frame.data
        )
        try await outbound.write(.custom(frame))
    }
}

let app = Application(
    router: router,
    server: .http1WebSocketUpgrade(webSocketRouter: router, configuration: .init(extensions: [.perMessageDeflate()])),
    logger: logger
)
try await app.runService()
