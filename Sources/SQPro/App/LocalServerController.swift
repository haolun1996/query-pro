import Observation
import SQCore

/// The local MySQL server's state, shared by the home screen and the "Can't connect" view.
@Observable
final class LocalServerController {
    private(set) var status = LocalMySQLServer.Status.notInstalled
    private(set) var isBusy = false
    var lastError: String?

    func refresh() async {
        guard !isBusy else { return }
        status = await LocalMySQLServer.status()
    }

    /// Returns whether the server is running afterwards.
    @discardableResult
    func start() async -> Bool {
        await change { () async throws(LocalMySQLServer.Failure) in try await LocalMySQLServer.start() }
        return status == .running
    }

    func stop() async {
        await change { () async throws(LocalMySQLServer.Failure) in try await LocalMySQLServer.stop() }
    }

    private func change(_ action: () async throws(LocalMySQLServer.Failure) -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        do {
            try await action()
        } catch .cancelled {
        } catch {
            lastError = error.localizedDescription
        }
        isBusy = false
        await refresh()
    }
}
