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

import Hummingbird
import HummingbirdWebSocket
import HummingbirdWSClient
@testable import HummingbirdWSCore
import NIOCore
import NIOPosix
import XCTest

final class HummingbirdWebSocketExtensionTests: XCTestCase {
    func testExtensionHeaderParsing() {
        let headers: HTTPHeaders = ["Sec-WebSocket-Extensions": "permessage-deflate; client_max_window_bits; server_max_window_bits=10, permessage-deflate;client_max_window_bits"]
        let extensions = WebSocketExtensionHTTPParameters.parseHeaders(headers, type: .server)
        XCTAssertEqual(
            extensions, 
            [
                .perMessageDeflate(maxWindow: 10, noContextTakeover: false, supportsMaxWindow: true, supportsNoContextTakeover: false), 
                .perMessageDeflate(maxWindow: nil, noContextTakeover: false, supportsMaxWindow: true, supportsNoContextTakeover: false)
            ]
        )
    }

    func testExtensionResponse() {
        let requestExt: [WebSocketExtensionHTTPParameters] = [
            .perMessageDeflate(maxWindow: 10, noContextTakeover: false, supportsMaxWindow: false, supportsNoContextTakeover: true), 
            .perMessageDeflate(maxWindow: nil, noContextTakeover: false, supportsMaxWindow: false, supportsNoContextTakeover: false)
        ]
        let ext = WebSocketExtensionConfig.perMessageDeflate(maxWindow: nil, noContextTakeover: true)
        XCTAssertEqual(
            [ext].respond(to: requestExt), 
            [.perMessageDeflate(requestMaxWindow: 10, requestNoContextTakeover: true, responseMaxWindow: nil, responseNoContextTakeover: true)]
        )
    }
}
