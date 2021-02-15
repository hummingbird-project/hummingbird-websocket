import Hummingbird
import HummingbirdWSCore

extension HBRequest {
    var webSocket: HBWebSocket? {
        get { self.extensions.get(\.webSocket) }
        set { self.extensions.set(\.webSocket, value: newValue) }
    }

    var webSocketTestShouldUpgrade: Bool? {
        get { self.extensions.get(\.webSocketTestShouldUpgrade) }
        set { self.extensions.set(\.webSocketTestShouldUpgrade, value: newValue) }
    }
}
