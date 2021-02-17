# Hummingbird Websocket

Adds support for upgrading HTTP connections to WebSocket. 

## Usage

```swift
let app = HBApplication()
// add HTTP to WebSocket upgrade
app.ws.addUpgrade()
// add middleware to websocket initial requests
app.ws.add(middleware: HBLogRequestsMiddleware(.info))
// on websocket connect. 
app.ws.on("/ws") { req, ws in
    // send ping and wait for pong and repeat every 60 seconds
    ws.initiateAutoPing(interval: .seconds(60))
    // on read from client send the same data back
    ws.onRead { data, ws in
        ws.write(data)
    }
}
app.start()
app.wait()
```
