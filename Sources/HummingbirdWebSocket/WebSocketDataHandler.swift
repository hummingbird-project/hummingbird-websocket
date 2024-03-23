//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2023-2024 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import AsyncAlgorithms
import HTTPTypes
import Logging
import NIOCore
import NIOWebSocket

/// Function that handles websocket data and text blocks
public typealias WebSocketDataHandler<Context: WebSocketContextProtocol> = @Sendable (WebSocketInboundStream, WebSocketOutboundWriter<Context>, Context) async throws -> Void
