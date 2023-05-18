import ExtrasBase64
import Hummingbird
import HummingbirdWSCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import Crypto
import struct Foundation.Data

// - this is needed to allow HummingbirdWebSocket to have precise control over the headers that are sent to the server.
public final class HBWebSocketClientUpgrader: NIOHTTPClientProtocolUpgrader {
	/// Errors that may be throwin into an instance's `upgradePromise
	public enum Error:Swift.Error {
		public enum ResponsePart:String {
			case httpStatus = "http status"
			case websocketAcceptValue = "websocket accept value"
		}
		/// a general error that is thrown when the upgrade could not be completed
		case invalidResponse(ResponsePart)

		/// a specific error that is thrown when a redirect error is encountered
		case requestRedirected(String)
	}

	/// Required for NIOHTTPClientProtocolUpgrader - defines the protocol that this upgrader supports.
	public let supportedProtocol: String = "websocket"

	/// Required by NIOHTTPClientProtocolUpgrader - defines the headers that must be present in the upgrade response for the upgrade to be successful.
	/// - This is needed for certain protocols, but not for websockets, so we can leave this alone.
	public let requiredUpgradeHeaders: [String] = []

	/// The host to send in the `Host` HTTP header.
	private let host:String
	/// The headers that may be added to the HTTP request.
	private let headers: HTTPHeaders
	/// Request key to be assigned to the `Sec-WebSocket-Key` HTTP header.
	private let requestKey: String
	/// Largest incoming `WebSocketFrame` size in bytes. This is used to set the `maxFrameSize` on the `WebSocket` channel handler upon a successful upgrade.
	private let maxFrameSize: Int
	/// If true, adds `WebSocketProtocolErrorHandler` to the channel pipeline to catch and respond to WebSocket protocol errors.
	private let automaticErrorHandling: Bool
	/// Called once the upgrade was successful or unsuccessful.
	private let upgradePromise:EventLoopPromise<Void>
	/// Called once the upgrade was successful. This is the owners opportunity to add any needed handlers to the channel pipeline.
	private let upgradeInitiator: (Channel, HTTPResponseHead) -> EventLoopFuture<Void>
	
	/// - Parameters:
	///   - host: sent to the server in the `Host` HTTP header. 
	///     - Default is "localhost".
	///   - requestKey: sent to the server in the `Sec-WebSocket-Key` HTTP header.
	///   - maxFrameSize: largest incoming `WebSocketFrame` size in bytes.
	///   - automaticErrorHandling: If true, adds `WebSocketProtocolErrorHandler` to the channel pipeline to catch and respond to WebSocket protocol errors. Default is true.
	///   - upgradePipelineHandler: called once the upgrade was successful
	public init(
		host:String = "localhost",
		headers: HTTPHeaders = [:],
		requestKey: String,
		maxFrameSize: Int,
		automaticErrorHandling: Bool = true,
		upgradePromise:EventLoopPromise<Void>,
		upgradeInitiator: @escaping (Channel, HTTPResponseHead) -> EventLoopFuture<Void>
	) {
		precondition(requestKey != "", "The request key must contain a valid Sec-WebSocket-Key")
		precondition(maxFrameSize <= UInt32.max, "invalid overlarge max frame size")
		self.host = host
		self.requestKey = requestKey
		self.maxFrameSize = maxFrameSize
		self.automaticErrorHandling = automaticErrorHandling
		self.upgradePromise = upgradePromise
		self.upgradeInitiator = upgradeInitiator
	}

	/// Adds additional headers that are needed for a WebSocket upgrade request. It is important that it is done this way, as to have the "final say" in the values of these headers before they are written.
	public func addCustom(upgradeRequestHeaders: inout HTTPHeaders) {
		upgradeRequestHeaders.replaceOrAdd(name: "Sec-WebSocket-Key", value: self.requestKey)
		upgradeRequestHeaders.replaceOrAdd(name: "Sec-WebSocket-Version", value: "13")
		// RFC 6455 requires this to be case-insensitively compared. However, many server sockets check explicitly for == "Upgrade", and SwiftNIO will (by default) send a header that is "upgrade" if not for this custom implementation with the NIOHTTPProtocolUpgrader protocol.
		upgradeRequestHeaders.replaceOrAdd(name: "Connection", value: "Upgrade")
		upgradeRequestHeaders.replaceOrAdd(name: "Upgrade", value: "websocket")
		upgradeRequestHeaders.replaceOrAdd(name: "Host", value: self.host)

		// allow the user to write the final headers (overriding anything they may want)
		for curHeader in upgradeRequestHeaders {
			upgradeRequestHeaders.replaceOrAdd(name: curHeader.name, value: curHeader.value)
		}
	}

	/// Allow or deny the upgrade based on the upgrade HTTP response
	/// headers containing the correct accept key.
	public func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
		// determine a basic path forward based on the HTTP response status code
		switch upgradeResponse.status {
			case .movedPermanently, .found, .seeOther, .notModified, .useProxy, .temporaryRedirect, .permanentRedirect:
				// redirect response likely
				guard let hasNewLocation = (upgradeResponse.headers["Location"].first ?? upgradeResponse.headers["location"].first) else {
					self.upgradePromise.fail(Error.invalidResponse(.httpStatus))
					return false
				}
				self.upgradePromise.fail(Error.requestRedirected(hasNewLocation))
				return false
			case .switchingProtocols:
				// this is the only path forward. lets go.
				break
			default:
				// unknown response
				self.upgradePromise.fail(Error.invalidResponse(.httpStatus))
				return false
		}
		
		// Validate the response key in 'Sec-WebSocket-Accept'.
		let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
		let acceptKey = requestKey + magicGUID
		let acceptData = Data(acceptKey.utf8)
		let acceptHash = Insecure.SHA1.hash(data: acceptData)
		let computed = acceptHash.withUnsafeBytes { (unsafeRawBufferPointer) -> String in
			let hashData = Data(unsafeRawBufferPointer)
			return hashData.base64EncodedString()
		}
		let acceptValueHeader = upgradeResponse.headers["Sec-WebSocket-Accept"]
		guard acceptValueHeader.count == 1 else {
			self.upgradePromise.fail(Error.invalidResponse(.websocketAcceptValue))
			return false
		}
		return acceptValueHeader[0] == computed
	}

	/// Called when the upgrade response has been flushed and it is safe to mutate the channel pipeline. Adds channel handlers for websocket frame encoding, decoding and errors.
	/// - Return value: An EventLoopFuture which will cause NIO to buffer inbound data to the channel until the future completes. This is to ensure that no data is lost in the upgrade as channels are swapped and replaced.
	public func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {
		var useHandlers:[NIOCore.ChannelHandler] = [ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize:self.maxFrameSize))]
		if self.automaticErrorHandling {
			useHandlers.append(WebSocketProtocolErrorHandler())
		}
		let upgradeFuture:EventLoopFuture<Void> = context.pipeline.addHandler(WebSocketFrameEncoder()).flatMap { [uh = useHandlers, chan = context.channel, upR = upgradeResponse, upI = self.upgradeInitiator] in
			context.pipeline.addHandlers(uh).flatMap { [ch = chan, ur = upR, ui = upI] in
				ui(ch, ur)
			}
		}
		upgradeFuture.cascade(to: self.upgradePromise)
		return upgradeFuture
	}
}