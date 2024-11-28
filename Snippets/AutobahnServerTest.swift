import Hummingbird
import HummingbirdWebSocket
import Logging
import WSCompression

// Autobahn tests (https://github.com/crossbario/autobahn-testsuite)
// run
// ```
// .scripts/autobahn.sh
// ```
// 1. Framing                                       (passed)
// 2. Pings/Pongs                                   (passed)
// 3. Reserved bits (not supported)                 (reserved bit checking not supported)
// 4. Opcodes                                       (passed)
// 5. Fragmentation                                 (passed)
// 6. UTF8 handling (not supported)                 (utf8 validation not supported)
// 7. Close handling                                (passed, except 7.5.1)
// 9. Limits/performance                            (passed)
// 10. Misc                                         (passed)
// 12. WebSocket compression (different payloads)   (not run)
// 13. WebSocket compression (different parameters) (not run)

var logger = Logger(label: "TestClient")
logger.logLevel = .trace

// let router = Router().get("report") {}

let app = Application(
    router: Router(),
    server: .http1WebSocketUpgrade(
        configuration: .init(maxFrameSize: 16_777_216, extensions: [.perMessageDeflate(maxDecompressedFrameSize: 16_777_216)])
    ) { _, _, _ in
        return .upgrade([:]) { inbound, outbound, _ in
            for try await msg in inbound.messages(maxSize: .max) {
                switch msg {
                case .binary(let buffer):
                    try await outbound.write(.binary(buffer))
                case .text(let string):
                    try await outbound.write(.text(string))
                }
            }
        }
    },
    configuration: .init(address: .hostname("127.0.0.1", port: 9001)),
    logger: logger
)
try await app.runService()
