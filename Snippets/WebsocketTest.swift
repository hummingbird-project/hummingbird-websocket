import Hummingbird
import HummingbirdFoundation
import HummingbirdWebSocket

let router = HBRouter()
router.get { _,_ in
    "Hello"
}
router.middlewares.add(HBFileMiddleware("Snippets/public"))
let app = HBApplication(responder: router.buildResponder(), server: .httpAndWebSocket())
try await app.runService()