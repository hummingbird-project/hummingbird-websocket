import HummingbirdWSClient
import Logging

var logger = Logger(label: "TestClient")
logger.logLevel = .trace
do {
    try await WebSocketClient.connect(
        url: .init("https://echo.websocket.org"),
        configuration: .init(maxFrameSize: 1 << 16),
        logger: logger
    ) { inbound, outbound, _ in
        try await outbound.write(.text("Hello"))
        for try await msg in inbound.messages(maxSize: .max) {
            print(msg)
        }
    }
} catch {
    logger.error("Error: \(error)")
}
