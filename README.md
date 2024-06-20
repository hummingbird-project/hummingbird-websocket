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
