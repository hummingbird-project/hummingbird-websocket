import NIO
import NIOWebSocket

enum WebSocketData {
    case text(String)
    case binary(ByteBuffer)
}

struct WebSocketFrameSequence {
    enum SequenceType {
        case text
        case binary
    }
    var buffer: ByteBuffer
    var type: SequenceType

    init(type: SequenceType) {
        self.buffer = ByteBufferAllocator().buffer(capacity: 0)
        self.type = type
    }

    mutating func append(_ frame: WebSocketFrame) {
        var data = frame.unmaskedData
        self.buffer.writeBuffer(&data)
    }
    
    var result: WebSocketData {
        switch type {
        case .text:
            return .text(String(buffer: self.buffer))
        case .binary:
            return .binary(self.buffer)
        }
    }
}

