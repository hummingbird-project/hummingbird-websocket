import ExtrasBase64
import Hummingbird
import HummingbirdWSCore
import NIO
//import NIOSSL
import NIOWebSocket

public final class HBWebSocketClient {
    static func createWebSocket(url: HBURL, configuration: Configuration, on eventLoop: EventLoop) -> EventLoopFuture<HBWebSocket> {
       let wsPromise = eventLoop.makePromise(of: HBWebSocket.self)

        do {
            let bootstrap = try createBootstrap(url: url, configuration: configuration, on: eventLoop)
            bootstrap
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    return Self.setupChannelForWebsockets(url: url, channel: channel, wsPromise: wsPromise, on: eventLoop)
                }
                .connect(host: url.host!, port: url.port ?? 80)
                .cascadeFailure(to: wsPromise)

            if url.scheme == .https || url.scheme == .wss {
                bootstrap.enableTLS()
            }
        } catch {
            wsPromise.fail(error)
        }
        return wsPromise.futureResult
    }

    static func createBootstrap(url: HBURL, configuration: Configuration, on eventLoop: EventLoop) throws -> NIOClientTCPBootstrap {
        if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
            //let sslContext = try NIOSSLContext(configuration: configuration.tlsConfiguration)
            //let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: url.host)
            return NIOClientTCPBootstrap(clientBootstrap, tls: NIOInsecureNoTLS())
        }
        preconditionFailure("Failed to create web socket bootstrap")
    }

    static func setupChannelForWebsockets(
        url: HBURL,
        channel: Channel,
        wsPromise: EventLoopPromise<HBWebSocket>,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        let upgradePromise = eventLoop.makePromise(of: Void.self)
        // initial HTTP request handler, before upgrade
        let httpHandler = WebSocketInitialRequestHandler(
            host: url.host!,
            urlPath: url.path,
            upgradePromise: upgradePromise
        )
        upgradePromise.futureResult.cascadeFailure(to: wsPromise)

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
        case websocketUpgradeFailed
    }

    public struct Configuration {
/*        let tlsConfiguration: TLSConfiguration

        public init(
            tlsConfiguration: TLSConfiguration = TLSConfiguration.forClient()
        ) {
            self.tlsConfiguration = tlsConfiguration
        }*/
    }
}
