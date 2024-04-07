import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import HummingbirdWSCompression
import Logging

var logger = Logger(label: "Echo")
logger.logLevel = .trace
let router = Router(context: BasicWebSocketRequestContext.self)
router.middlewares.add(FileMiddleware("Snippets/public"))
router.get { _, _ in
    "Hello"
}

router.ws("/ws") { inbound, outbound, _ in
    for try await frame in inbound {
        if frame.opcode == .text, String(buffer: frame.data) == "disconnect", frame.fin == true {
            break
        }
        if frame.opcode == .binary, frame.data.readableBytes > 2 {
            var unmaskedData = frame.unmaskedData
            try await outbound.withBinaryMessageWriter { write in
                let firstHalf = unmaskedData.readSlice(length: frame.data.readableBytes / 2)!
                try await write(firstHalf)
                try await write(unmaskedData)
            }
        } else {
            var frame = frame
            frame.data = frame.unmaskedData
            frame.maskKey = nil
            try await outbound.write(.custom(frame))
        }
    }
}

let app = Application(
    router: router,
    server: .http1WebSocketUpgrade(webSocketRouter: router, configuration: .init(extensions: [.perMessageDeflate()])),
    logger: logger
)
try await app.runService()
