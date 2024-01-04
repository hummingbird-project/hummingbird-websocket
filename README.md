# Hummingbird Websocket

Adds support for upgrading HTTP connections to WebSocket. 

## Usage

```swift
let app = HBApplication(
    router: router,
    server: .httpAndWebSocket { channel, head in
        if head.uri == "ws" {
            return .upgrade(HTTPHeaders()) { inbound, outbound, _ in
                for try await packet in inbound {
                    if case .text("disconnect") = packet {
                        break
                    }
                    try await outbound.write(.custom(packet.webSocketFrame))
                }
            }
        } else {
            return .dontUpgrade
        }
    }
)
app.runService()
```

## Documentation

You can find reference documentation for HummingbirdWebSocket [here](https://hummingbird-project.github.io/hummingbird/current/hummingbird-websocket/index.html). The [hummingbird-examples](https://github.com/hummingbird-project/hummingbird-examples) repository has a number of examples of different uses of the library.
