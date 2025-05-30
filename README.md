<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://github.com/hummingbird-project/hummingbird/assets/9382567/48de534f-8301-44bd-b117-dfb614909efd">
  <img src="https://github.com/hummingbird-project/hummingbird/assets/9382567/e371ead8-7ca1-43e3-8077-61d8b5eab879">
</picture>
</p>  
<p align="center">
<a href="https://swift.org">
  <img src="https://img.shields.io/badge/swift-5.10-brightgreen.svg"/>
</a>
<a href="https://github.com/hummingbird-project/hummingbird-websocket/actions?query=workflow%3ACI">
  <img src="https://github.com/hummingbird-project/hummingbird-websocket/actions/workflows/ci.yml/badge.svg?branch=main"/>
</a>
<a href="https://discord.gg/7ME3nZ7mP2">
  <img src="https://img.shields.io/badge/chat-discord-brightgreen.svg"/>
</a>
</p>

# Hummingbird Websocket

Adds support for upgrading HTTP1 connections to WebSocket. 

## Usage

Setup WebSocket upgrades with a closure that either returns `.upgrade` with response headers and the handler for the WebSocket or a `.dontUpgrade`
```swift
let app = Application(
    router: router,
    server: .http1WebSocketUpgrade { request, channel, logger in
        // upgrade if request path is "/ws"
        guard request.path == "/ws" else { return .dontUpgrade }
        // The upgrade response includes the headers to include in the response and 
        // the WebSocket handler
        return .upgrade([:]) { inbound, outbound, context in
            for try await packet in inbound {
                // send "Received" for every packet we receive
                try await outbound.write(.text("Received"))
            }
        }
    }
)
app.runService()
```
Or alternatively use a `Router`. Using a router means you can add middleware to process the initial upgrade request before it is handled eg for authenticating the request.
```swift
let wsRouter = Router(context: BasicWebSocketRequestContext.self)
wsRouter.middlewares.add(BasicAuthenticator())
// An upgrade only occurs if a WebSocket path is matched
wsRouter.ws("/ws") { request, context in
    // allow upgrade
    .upgrade()
} onUpgrade: { inbound, outbound, context in
    for try await packet in inbound {
        // send "Received" for every packet we receive
        try await outbound.write(.text("Received"))
    }
}
let app = Application(
    router: router,
    server: .http1WebSocketUpgrade(webSocketRouter: wsRouter)
)
app.runService()
```

## Socket.IO-style Dual Transport

You can implement Socket.IO-style servers that handle both HTTP polling and WebSocket connections at the same endpoint. Socket.IO uses **both GET and POST requests** for its HTTP long-polling transport:
- **GET requests** for receiving data from the server (long-polling)
- **POST requests** for sending data to the server

### Multi-Method Router Approach

Use the multi-method `router.ws()` to handle both GET and POST requests in a single route:

```swift
let router = Router(context: BasicWebSocketRequestContext.self)

// Handle both GET and POST requests for Socket.IO compatibility
router.ws("/socket.io", methods: [.get, .post]) { request, context in
    let transport = request.uri.queryParameters["transport"] ?? "polling"
    
    if transport == "websocket" {
        // Upgrade to WebSocket
        return .upgrade([:])
    } else {
        // Handle HTTP polling
        if request.method == .get {
            // GET: receiving data (handshake/long-polling)
            let sessionId = UUID().uuidString
            let response = """
            {"sid":"\(sessionId)","upgrades":["websocket"],"pingInterval":25000,"pingTimeout":20000}
            """
            return .httpResponse(Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: response))
            ))
        } else if request.method == .post {
            // POST: sending data to server
            return .httpResponse(Response(
                status: .ok,
                headers: [.contentType: "text/plain"],
                body: .init(byteBuffer: ByteBuffer(string: "ok"))
            ))
        } else {
            return .dontUpgrade
        }
    }
} onUpgrade: { inbound, outbound, context in
    // Handle WebSocket connection
    try await outbound.write(.text("WebSocket connected"))
    for try await packet in inbound {
        // Echo messages back to client
        try await outbound.write(packet)
    }
}

let app = Application(
    router: router,
    server: .http1WebSocketUpgrade(webSocketRouter: router)
)
app.runService()
```

### Alternative: Middleware Pattern

For more complex routing scenarios, you can use middleware with `.continueToHTTP`:

```swift
let router = Router(context: BasicWebSocketRequestContext.self)

router.group("/socket.io")
    .add(middleware: WebSocketUpgradeMiddleware { request, context in
        let transport = request.uri.queryParameters["transport"] ?? "polling"
        return transport == "websocket" ? .upgrade([:]) : .continueToHTTP
    } onUpgrade: { inbound, outbound, context in
        // Handle WebSocket connection
        try await outbound.write(.text("WebSocket connected"))
        for try await packet in inbound {
            try await outbound.write(packet)
        }
    })
    .get { request, context in
        // Handle GET requests for receiving data (handshake/long-polling)
        let sessionId = UUID().uuidString
        let response = """
        {"sid":"\(sessionId)","upgrades":["websocket"],"pingInterval":25000,"pingTimeout":20000}
        """
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: response))
        )
    }
    .post { request, context in
        // Handle POST requests for sending data to server
        let body = try await request.body.collect(upTo: .max)
        // Process the Socket.IO packet data...
        return Response(
            status: .ok,
            headers: [.contentType: "text/plain"],
            body: .init(byteBuffer: ByteBuffer(string: "ok"))
        )
    }
```

### Single-Method Fallback

For simple cases that only need GET requests (legacy or WebSocket-only scenarios):

```swift
let router = Router(context: BasicWebSocketRequestContext.self)

// Traditional WebSocket-only route (GET requests only)
router.ws("/socket.io") { request, context in
    let transport = request.uri.queryParameters["transport"] ?? "polling"
    
    if transport == "websocket" {
        return .upgrade([:])
    } else {
        // Handle HTTP polling (GET only)
        let pollingResponse = handleSocketIOPolling(request, context)
        return .httpResponse(pollingResponse)
    }
} onUpgrade: { inbound, outbound, context in
    // Handle WebSocket connection
    for try await packet in inbound {
        try await outbound.write(packet)
    }
}
```

This enables:
- ✅ **Full Socket.IO server implementation** with GET/POST support
- ✅ Server-Sent Events with WebSocket fallback  
- ✅ GraphQL subscriptions with transport negotiation
- ✅ Any dual-transport real-time protocol

## Documentation

You can find documentation for HummingbirdWebSocket [here](https://hummingbird-project.github.io/hummingbird-docs/2.0/documentation/hummingbirdwebsocket). The [hummingbird-examples](https://github.com/hummingbird-project/hummingbird-examples) repository has a number of examples of different uses of the library.
