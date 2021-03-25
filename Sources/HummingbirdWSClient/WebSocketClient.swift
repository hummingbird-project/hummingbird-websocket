import ExtrasBase64
import Hummingbird
import HummingbirdWSCore
import NIO
import NIOSSL
import NIOWebSocket

public final class HBWebSocketClient {
    public static func connect(url: HBURL, configuration: Configuration, on eventLoop: EventLoop) -> EventLoopFuture<HBWebSocket> {
        let wsPromise = eventLoop.makePromise(of: HBWebSocket.self)
        do {
            let url = try SplitURL(url: url)
            let bootstrap = try createBootstrap(url: url, configuration: configuration, on: eventLoop)
            bootstrap
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    return Self.setupChannelForWebsockets(url: url, channel: channel, wsPromise: wsPromise, on: eventLoop)
                }
                .connect(host: url.host, port: url.port)
                .cascadeFailure(to: wsPromise)

        } catch {
            wsPromise.fail(error)
        }
        return wsPromise.futureResult
    }

    static func createBootstrap(url: SplitURL, configuration: Configuration, on eventLoop: EventLoop) throws -> NIOClientTCPBootstrap {
        if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
            let sslContext = try NIOSSLContext(configuration: configuration.tlsConfiguration)
            let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: url.host)
            let bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
            if url.tlsRequired {
                bootstrap.enableTLS()
            }
            return bootstrap
        }
        preconditionFailure("Failed to create web socket bootstrap")
    }

    static func setupChannelForWebsockets(
        url: SplitURL,
        channel: Channel,
        wsPromise: EventLoopPromise<HBWebSocket>,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        let upgradePromise = eventLoop.makePromise(of: Void.self)
        upgradePromise.futureResult.cascadeFailure(to: wsPromise)

        // initial HTTP request handler, before upgrade
        let httpHandler: WebSocketInitialRequestHandler
        do {
            httpHandler = try WebSocketInitialRequestHandler(
                url: url,
                upgradePromise: upgradePromise
            )
        } catch {
            upgradePromise.fail(Error.invalidURL)
            return upgradePromise.futureResult
        }

        // create random key for request key
        let requestKey = (0..<16).map { _ in UInt8.random(in: .min ..< .max)}
        let base64Key = String(base64Encoding: requestKey, options: [])
        let websocketUpgrader = NIOWebSocketClientUpgrader(requestKey: base64Key) { channel, req in
            let webSocket = HBWebSocket(channel: channel, type: .client)
            return channel.pipeline.addHandler(WebSocketHandler(webSocket: webSocket)).map { _ -> Void in
                wsPromise.succeed(webSocket)
                upgradePromise.succeed(Void())
            }
        }

        let config: NIOHTTPClientUpgradeConfiguration = (
            upgraders: [ websocketUpgrader ],
            completionHandler: { _ in
                channel.pipeline.removeHandler(httpHandler, promise: nil)
        })

        // add HTTP handler with web socket upgrade
        return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
            channel.pipeline.addHandler(httpHandler)
        }
    }

    public enum Error: Swift.Error {
        case invalidURL
        case websocketUpgradeFailed
    }

    public struct Configuration {
        let tlsConfiguration: TLSConfiguration

        public init(
            tlsConfiguration: TLSConfiguration = TLSConfiguration.forClient()
        ) {
            self.tlsConfiguration = tlsConfiguration
        }
    }

    struct SplitURL {
        let host: String
        let pathQuery: String
        let port: Int
        let tlsRequired: Bool

        init(url: HBURL) throws {
            guard let host = url.host else { throw HBWebSocketClient.Error.invalidURL }
            self.host = host
            if let port = url.port {
                self.port = port
            } else {
                if url.scheme == .https || url.scheme == .wss {
                    self.port = 443
                } else {
                    self.port = 80
                }
            }
            self.tlsRequired = url.scheme == .https || url.scheme == .wss ? true : false
            self.pathQuery = url.path + (url.query ?? "")
        }
    }
}
