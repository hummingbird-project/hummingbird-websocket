import HummingbirdWSClient
import Logging

let cases = 1...10

var logger = Logger(label: "TestClient")
logger.logLevel = .trace
do {
    for c in cases {
        logger.info("Case \(c)")
        try await WebSocketClient.connect(
            url: .init("ws://127.0.0.1:9001/runCase?case=\(c)&agent=HB"),
            configuration: .init(maxFrameSize: 1 << 16),
            logger: logger
        ) { inbound, outbound, _ in
            for try await msg in inbound.messages(maxSize: .max) {
                switch msg {
                case .binary(let buffer):
                    try await outbound.write(.binary(buffer))
                case .text(let string):
                    try await outbound.write(.text(string))
                }
            }
        }
    }
    try await WebSocketClient.connect(url: .init("ws://127.0.0.1:9001/updateReports?agent=HB"), logger: logger) { inbound, _, _ in
        for try await _ in inbound {}
    }
} catch {
    logger.error("Error: \(error)")
}
