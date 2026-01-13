//
// This source file is part of the Hummingbird server framework project
// Copyright (c) the Hummingbird authors
//
// See LICENSE.txt for license information
// SPDX-License-Identifier: Apache-2.0
//

import Hummingbird
import HummingbirdCore
import HummingbirdWebSocket
import Logging
import NIOCore
import NIOWebSocket
import ServiceLifecycle
import Testing
import WSClient
@_spi(WSInternal) @testable import WSCore

@testable import WSCompression

@Suite(.serialized)
struct HummingbirdWebSocketExtensionTests {
    /// Create random buffer
    /// - Parameters:
    ///   - size: size of buffer
    ///   - randomness: how random you want the buffer to be (percentage)
    func createRandomBuffer(size: Int, randomness: Int = 100) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: size)
        let randomness = (randomness * randomness) / 100
        for i in 0..<size {
            let random = Int.random(in: 0..<25600)
            if random < randomness * 256 {
                buffer.writeInteger(UInt8(random & 0xFF))
            } else {
                buffer.writeInteger(UInt8(i & 0xFF))
            }
        }
        return buffer
    }

    @Test func testPerMessageDeflate() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(
                configuration: .init(extensions: [.perMessageDeflate(minFrameSizeToCompress: 16)])
            ) { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let firstMessage = try await iterator.next()
                    #expect(firstMessage == .text("Hello, testing this is compressed"))
                    let secondMessage = try await iterator.next()
                    #expect(secondMessage == .text("Hello"))
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws(
                "/",
                configuration: .init(extensions: [.perMessageDeflate(minFrameSizeToCompress: 16)])
            ) { inbound, outbound, _ in
                try await outbound.write(.text("Hello, testing this is compressed"))
                try await outbound.write(.text("Hello"))
                for try await _ in inbound {}
            }
        }
    }

    @Test func testPerMessageDeflateMaxWindow() async throws {
        let buffer = self.createRandomBuffer(size: 4096, randomness: 10)
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(
                configuration: .init(extensions: [.perMessageDeflate(minFrameSizeToCompress: 16)])
            ) { _, _, _ in
                .upgrade([:]) { inbound, outbound, _ in
                    let extensions = await outbound.handler.configuration.extensions
                    #expect((extensions.first as? PerMessageDeflateExtension)?.configuration.receiveMaxWindow == 10)
                    for try await data in inbound.messages(maxSize: .max) {
                        #expect(data == .binary(buffer))
                    }
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws(
                "/",
                configuration: .init(extensions: [.perMessageDeflate(maxWindow: 10, minFrameSizeToCompress: 16)])
            ) { _, outbound, _ in
                let extensions = await outbound.handler.configuration.extensions
                #expect((extensions.first as? PerMessageDeflateExtension)?.configuration.sendMaxWindow == 10)
                try await outbound.write(.binary(buffer))
            }
        }
    }

    @Test func testPerMessageDeflateNoContextTakeover() async throws {
        let buffer = self.createRandomBuffer(size: 4096, randomness: 10)
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(
                configuration: .init(extensions: [.perMessageDeflate(minFrameSizeToCompress: 16)])
            ) { _, _, _ in
                .upgrade([:]) { inbound, outbound, _ in
                    let extensions = await outbound.handler.configuration.extensions
                    #expect((extensions.first as? PerMessageDeflateExtension)?.configuration.receiveNoContextTakeover == true)
                    for try await data in inbound.messages(maxSize: .max) {
                        #expect(data == .binary(buffer))
                    }
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws(
                "/",
                configuration: .init(extensions: [.perMessageDeflate(clientNoContextTakeover: true, minFrameSizeToCompress: 16)])
            ) { _, outbound, _ in
                let extensions = await outbound.handler.configuration.extensions
                #expect((extensions.first as? PerMessageDeflateExtension)?.configuration.sendNoContextTakeover == true)

                try await outbound.write(.binary(buffer))
            }
        }
    }

    @Test func testPerMessageExtensionOrdering() async throws {
        let buffer = self.createRandomBuffer(size: 4096, randomness: 10)
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(
                configuration: .init(extensions: [.xor(), .perMessageDeflate(serverNoContextTakeover: true, minFrameSizeToCompress: 16)])
            ) { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    for try await data in inbound.messages(maxSize: .max) {
                        #expect(data == .binary(buffer))
                    }
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws(
                "/",
                configuration: .init(extensions: [.xor(value: 34), .perMessageDeflate(minFrameSizeToCompress: 16)])
            ) { _, outbound, _ in
                try await outbound.write(.binary(buffer))
            }
        }
    }

    @Test func testPerMessageDeflateWithRouter() async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/test") { inbound, _, _ in
            var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
            let firstMessage = try await iterator.next()
            #expect(firstMessage == .text("Hello, testing this is compressed"))
            let secondMessage = try await iterator.next()
            #expect(secondMessage == .text("Hello"))
        }
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(
                webSocketRouter: router,
                configuration: .init(extensions: [.perMessageDeflate(minFrameSizeToCompress: 16)])
            ),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws(
                "/test",
                configuration: .init(extensions: [.perMessageDeflate(minFrameSizeToCompress: 16)])
            ) { inbound, outbound, _ in
                try await outbound.write(.text("Hello, testing this is compressed"))
                try await outbound.write(.text("Hello"))
                for try await _ in inbound {}
            }
        }
    }

    @Test func testPerMessageDeflateMultiFrameMessage() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(
                configuration: .init(extensions: [.perMessageDeflate(minFrameSizeToCompress: 16)])
            ) { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let firstMessage = try await iterator.next()
                    #expect(firstMessage == .text("Hello, testing this is compressed"))
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws(
                "/",
                configuration: .init(extensions: [.perMessageDeflate(minFrameSizeToCompress: 16)])
            ) { _, outbound, _ in
                try await outbound.withTextMessageWriter { write in
                    try await write("Hello, ")
                    try await write("testing this is compressed")
                }
            }
        }
    }

    @Test func testCheckDeflate() async throws {
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(
                configuration: .init(extensions: [.checkDeflate(), .perMessageDeflate(minFrameSizeToCompress: 16)])
            ) { _, _, _ in
                .upgrade([:]) { inbound, _, _ in
                    var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let firstMessage = try await iterator.next()
                    // The first message should be received
                    #expect(firstMessage == .text("Hello, testing this is compressed"))
                    // The second message will not be received because the checkDeflate extension throws
                    // an error because it hasn't been compressed
                    let nextMessage = try await iterator.next()
                    #expect(nextMessage == nil)
                }
            },
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws(
                "/",
                configuration: .init(extensions: [.checkDeflate(), .perMessageDeflate(minFrameSizeToCompress: 16)])
            ) { inbound, outbound, _ in
                try await outbound.write(.text("Hello, testing this is compressed"))
                try await outbound.write(.text("Hello"))
                for try await _ in inbound {}
            }
        }
    }
}

/// Extension that XORs data with a specific value
struct XorWebSocketExtension: WebSocketExtension {
    let name = "xor"
    func shutdown() {}

    func xorFrame(_ frame: WebSocketFrame, context: WebSocketExtensionContext) -> WebSocketFrame {
        var newBuffer = ByteBufferAllocator().buffer(capacity: frame.data.readableBytes)
        for byte in frame.unmaskedData.readableBytesView {
            newBuffer.writeInteger(byte ^ self.value)
        }
        var frame = frame
        frame.data = newBuffer
        frame.maskKey = nil
        return frame
    }

    func processReceivedFrame(_ frame: WebSocketFrame, context: WebSocketExtensionContext) -> WebSocketFrame {
        self.xorFrame(frame, context: context)
    }

    func processFrameToSend(_ frame: WebSocketFrame, context: WebSocketExtensionContext) throws -> WebSocketFrame {
        self.xorFrame(frame, context: context)
    }

    let value: UInt8
}

struct XorWebSocketExtensionBuilder: WebSocketExtensionBuilder {
    static let name = "permessage-xor"
    let value: UInt8?

    init(value: UInt8? = nil) {
        self.value = value
    }

    func clientRequestHeader() -> String {
        var header = Self.name
        if let value {
            header += ";value=\(value)"
        }
        return header
    }

    func serverReponseHeader(to request: WebSocketExtensionHTTPParameters) -> String? {
        var header = Self.name
        if let value = request.parameters["value"]?.integer {
            header += ";value=\(value)"
        }
        return header
    }

    func serverExtension(from request: WebSocketExtensionHTTPParameters) throws -> (WebSocketExtension)? {
        XorWebSocketExtension(value: UInt8(request.parameters["value"]?.integer ?? 255))
    }

    func clientExtension(from request: WebSocketExtensionHTTPParameters) throws -> (WebSocketExtension)? {
        XorWebSocketExtension(value: UInt8(request.parameters["value"]?.integer ?? 255))
    }
}

extension WebSocketExtensionFactory {
    static func xor(value: UInt8? = nil) -> WebSocketExtensionFactory {
        .init { XorWebSocketExtensionBuilder(value: value) }
    }
}

/// Extension that checks whether frames coming in have been compressed
struct CheckDeflateWebSocketExtension: WebSocketExtension {
    struct NoDeflateError: Error {}
    let name = "check-deflate"
    func shutdown() {}

    func processReceivedFrame(_ frame: WebSocketFrame, context: WebSocketExtensionContext) throws -> WebSocketFrame {
        guard frame.rsv1 else { throw NoDeflateError() }
        return frame
    }

    func processFrameToSend(_ frame: WebSocketFrame, context: WebSocketExtensionContext) throws -> WebSocketFrame {
        frame
    }
}

struct CheckDeflateWebSocketExtensionBuilder: WebSocketExtensionBuilder {
    static let name = "check-deflate"

    func clientRequestHeader() -> String {
        Self.name
    }

    func serverReponseHeader(to request: WebSocketExtensionHTTPParameters) -> String? {
        Self.name
    }

    func serverExtension(from request: WebSocketExtensionHTTPParameters) throws -> (WebSocketExtension)? {
        CheckDeflateWebSocketExtension()
    }

    func clientExtension(from request: WebSocketExtensionHTTPParameters) throws -> (WebSocketExtension)? {
        CheckDeflateWebSocketExtension()
    }
}

extension WebSocketExtensionFactory {
    static func checkDeflate() -> WebSocketExtensionFactory {
        .init { CheckDeflateWebSocketExtensionBuilder() }
    }
}
