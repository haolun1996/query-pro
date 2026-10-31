import Foundation
import MySQLNIO
import NIOCore

public enum ErrorText {
    /// Workbench-style message, e.g. "Error Code: 1064. You have an error in your SQL syntax…"
    public static func message(for error: any Error) -> String {
        switch error {
        case MySQLError.server(let packet):
            "Error Code: \(packet.errorCode.rawValue). \(packet.errorMessage)"
        case let error as MySQLError:
            error.message
        case let error as IOError:
            "Can't connect to the server (\(error.description))."
        case let error as LocalizedError:
            error.errorDescription ?? "\(error)"
        default:
            "\(error)"
        }
    }

    /// `true` for wrong user/password, so the app can ask for the password again.
    public static func isAccessDenied(_ error: any Error) -> Bool {
        if case MySQLError.server(let packet) = error { return packet.errorCode.rawValue == 1045 }
        return false
    }
}
