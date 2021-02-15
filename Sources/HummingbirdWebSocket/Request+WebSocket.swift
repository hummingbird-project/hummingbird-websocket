import Hummingbird
import HummingbirdWSCore

extension HBRequest {
    var webSocket: HBWebSocket? {
        get { self.extensions.get(\.webSocket) }
        set { self.extensions.set(\.webSocket, value: newValue) }
    }
}
