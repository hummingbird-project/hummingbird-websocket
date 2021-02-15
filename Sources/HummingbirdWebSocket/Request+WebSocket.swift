import Hummingbird
import HummingbirdWSCore

extension HBRequest {
    /// WebSocket attached to request
    var webSocket: HBWebSocket? {
        get { self.extensions.get(\.webSocket) }
        set { self.extensions.set(\.webSocket, value: newValue) }
    }

    /// Is this request testing whether we should upgrade to a WebSocket connection
    var webSocketTestShouldUpgrade: Bool? {
        get { self.extensions.get(\.webSocketTestShouldUpgrade) }
        set { self.extensions.set(\.webSocketTestShouldUpgrade, value: newValue) }
    }
}

extension HBResponse {
    /// Can we upgrade to a web socket connection?
    var webSocketShouldUpgrade: Bool? {
        get { self.extensions.get(\.webSocketShouldUpgrade) }
        set { self.extensions.set(\.webSocketShouldUpgrade, value: newValue) }
    }
}
