//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTP1

/// Responsible for writing the initial HTTP request to the channel. This HTTP request is a crucial step in intiating a WebSocket connection.
final class WebSocketInitialRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
	public typealias InboundIn = Never
	public typealias OutboundOut = HTTPClientRequestPart

	let urlPath: String
	let headers: HTTPHeaders

	init(url:HBWebSocketClient.SplitURL, headers:HTTPHeaders = [:]) throws {
		self.urlPath = url.pathQuery
		self.headers = headers
	}

	// write the data as soon as the channel becomes available
	public func channelActive(context:ChannelHandlerContext) {
		var requestHead = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: self.urlPath)
		requestHead.headers = self.headers
		context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)
		context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
		context.flush()
	}

	public func errorCaught(context:ChannelHandlerContext, error:Error) {
		context.close(promise:nil)
	}
}
