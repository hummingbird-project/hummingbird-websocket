import HummingbirdWSClient
import HummingbirdWSCompression
import Logging

// Autobahn tests (https://github.com/crossbario/autobahn-testsuite)
// run
// ```
// .scripts/autobahn.sh
// ```
// 1. Framing                                       (passed)
// 2. Pings/Pongs                                   (passed)
// 3. Reserved bits                                 (reserved bit checking not supported)
// 4. Opcodes                                       (passed)
// 5. Fragmentation                                 (passed. 5.1/5.2 non-strict)
// 6. UTF8 handling                                 (utf8 validation not supported)
// 7. Close handling                                (passed, except 7.5.1)
// 9. Limits/performance                            (passed)
// 10. Misc                                         (passed)
// 12. WebSocket compression (different payloads)   (passed)
// 13. WebSocket compression (different parameters) (passed)

let cases = 1...1000

var logger = Logger(label: "TestClient")
logger.logLevel = .trace
do {
    for c in cases {
        logger.info("Case \(c)")
        try await WebSocketClient.connect(
            url: .init("ws://127.0.0.1:9001/runCase?case=\(c)&agent=HB"),
            configuration: .init(maxFrameSize: 16_777_216, extensions: [.perMessageDeflate(maxDecompressedFrameSize: 16_777_216)]),
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
} catch {
    logger.error("Error: \(error)")
}

try await WebSocketClient.connect(url: .init("ws://127.0.0.1:9001/updateReports?agent=HB"), logger: logger) { inbound, _, _ in
    for try await _ in inbound {}
}
