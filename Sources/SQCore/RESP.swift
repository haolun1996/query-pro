import Foundation
import NIOCore

/// A Redis reply in RESP2, the protocol every Redis since 1.2 speaks (Query Pro never sends `HELLO 3`).
public enum RESPValue: Equatable, Sendable {
    case simple(String)
    case error(String)
    case integer(Int64)
    /// `nil` is the null bulk string (`$-1`), e.g. GET on a missing key.
    case bulk(Data?)
    /// `nil` is the null array (`*-1`), e.g. a timed-out BLPOP.
    case array([RESPValue]?)

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// Simple and bulk strings as text (invalid UTF-8 is replaced), integers as digits.
    public var string: String? {
        switch self {
        case .simple(let text): text
        case .bulk(let data?): String(decoding: data, as: UTF8.self)
        case .integer(let value): String(value)
        default: nil
        }
    }

    public var data: Data? {
        switch self {
        case .simple(let text): Data(text.utf8)
        case .bulk(let data): data
        default: nil
        }
    }

    public var int: Int64? {
        switch self {
        case .integer(let value): value
        case .simple(let text), .error(let text): Int64(text)
        case .bulk(let data?): Int64(String(decoding: data, as: UTF8.self))
        default: nil
        }
    }

    public var array: [RESPValue]? {
        if case .array(let items) = self { return items }
        return nil
    }
}

public enum RESP {
    public struct ProtocolError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { "The server sent something that isn't a Redis reply (\(message))." }
    }

    /// Reads one complete reply from the front of `buffer`. Returns `nil`, leaving the buffer untouched, when the
    /// reply hasn't fully arrived yet.
    public static func parse(_ buffer: inout ByteBuffer) throws -> RESPValue? {
        var copy = buffer
        guard let value = try parseValue(&copy) else { return nil }
        buffer = copy
        return value
    }

    private static func parseValue(_ buffer: inout ByteBuffer) throws -> RESPValue? {
        guard let tag = buffer.readInteger(as: UInt8.self) else { return nil }
        switch tag {
        case UInt8(ascii: "+"):
            return readLine(&buffer).map { .simple($0) }
        case UInt8(ascii: "-"):
            return readLine(&buffer).map { .error($0) }
        case UInt8(ascii: ":"):
            guard let line = readLine(&buffer) else { return nil }
            guard let value = Int64(line) else { throw ProtocolError(message: "bad integer \(line)") }
            return .integer(value)
        case UInt8(ascii: "$"):
            guard let line = readLine(&buffer) else { return nil }
            guard let length = Int(line), length >= -1 else { throw ProtocolError(message: "bad length \(line)") }
            if length == -1 { return .bulk(nil) }
            guard buffer.readableBytes >= length + 2, let bytes = buffer.readBytes(length: length) else { return nil }
            buffer.moveReaderIndex(forwardBy: 2)
            return .bulk(Data(bytes))
        case UInt8(ascii: "*"):
            guard let line = readLine(&buffer) else { return nil }
            guard let count = Int(line), count >= -1 else { throw ProtocolError(message: "bad count \(line)") }
            if count == -1 { return .array(nil) }
            var items: [RESPValue] = []
            items.reserveCapacity(min(count, 4096))
            for _ in 0..<count {
                guard let item = try parseValue(&buffer) else { return nil }
                items.append(item)
            }
            return .array(items)
        default:
            throw ProtocolError(message: "unexpected byte \(tag)")
        }
    }

    private static func readLine(_ buffer: inout ByteBuffer) -> String? {
        let view = buffer.readableBytesView
        guard let cr = view.firstIndex(of: UInt8(ascii: "\r")), cr + 1 < view.endIndex, view[cr + 1] == UInt8(ascii: "\n") else {
            return nil
        }
        let line = buffer.readString(length: cr - view.startIndex) ?? ""
        buffer.moveReaderIndex(forwardBy: 2)
        return line
    }

    /// A command as Redis expects it from clients: an array of bulk strings.
    public static func encode(_ arguments: [Data], into buffer: inout ByteBuffer) {
        buffer.writeString("*\(arguments.count)\r\n")
        for argument in arguments {
            buffer.writeString("$\(argument.count)\r\n")
            buffer.writeBytes(argument)
            buffer.writeString("\r\n")
        }
    }
}
