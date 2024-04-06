# Hummingbird Websocket

Adds support for upgrading HTTP1 connections to WebSocket. 

## Usage

Setup WebSocket upgrades with a closure that either returns `.upgrade` with response headers and the handler for the WebSocket or a `.dontUpgrade`
```swift
let app = Application(
    router: router,
    server: .http1WebSocketUpgrade { request, channel, logger in
        // upgrade if request URI is "/ws"
        guard request.uri == "/ws" else { return .dontUpgrade }
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

## Documentation

You can find documentation for HummingbirdWebSocket [here](https://hummingbird-project.github.io/hummingbird-docs/2.0/documentation/hummingbirdwebsocket). The [hummingbird-examples](https://github.com/hummingbird-project/hummingbird-examples) repository has a number of examples of different uses of the library.
