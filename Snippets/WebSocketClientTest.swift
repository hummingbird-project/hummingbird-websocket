import HummingbirdWSClient
import Logging

var logger = Logger(label: "TestClient")
logger.logLevel = .trace
do {
    try await WebSocketClient.connect(url: "ws://127.0.0.1:9001", configuration: .init(), logger: logger) { inbound, outbound, _ in
        try await outbound.write(.text("Hello"))
        try await outbound.write(.text("Adam"))
        for try await _ in inbound {}
    }
} catch {
    logger.error("Error: \(error)")
}
