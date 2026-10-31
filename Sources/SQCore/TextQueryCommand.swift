import Foundation
import MySQLNIO

/// Runs one statement over the text protocol and keeps what `simpleQuery` throws away:
/// column definitions for empty result sets and the OK packet (affected rows, insert id).
final class TextQueryCommand: MySQLCommand, @unchecked Sendable {
    private enum State {
        case ready
        case columns(count: Int)
        case rows
        case done
    }

    let sql: String
    private var state = State.ready
    private(set) var columns: [MySQLProtocol.ColumnDefinition41] = []
    private(set) var rows: [[ByteBuffer?]] = []
    private(set) var ok: MySQLProtocol.OK_Packet?

    init(sql: String) {
        self.sql = sql
    }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        .init(response: [try .encode(MySQLProtocol.COM_QUERY(query: sql), capabilities: capabilities)])
    }

    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if packet.isError {
            state = .done
            throw MySQLError.server(try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities))
        }
        switch state {
        case .ready:
            if packet.isOK {
                ok = try packet.decode(MySQLProtocol.OK_Packet.self, capabilities: capabilities)
                state = .done
                return .init(done: true)
            }
            let response = try packet.decode(MySQLProtocol.COM_QUERY_Response.self, capabilities: capabilities)
            state = .columns(count: Int(response.columnCount))
            return .init()
        case .columns(let count):
            columns.append(try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities))
            if columns.count == count { state = .rows }
            return .init()
        case .rows:
            if packet.isEOF {
                state = .done
                return .init(done: true)
            }
            rows.append(try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: columns.count).values)
            return .init()
        case .done:
            throw MySQLError.protocolError
        }
    }
}
