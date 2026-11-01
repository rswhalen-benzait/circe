import Foundation
import Darwin
@testable import CirceVNC

/// Real loopback RFB handshakes; no SSH, cloud, microphone or login Keychain access.
func runSessionLifecycleTests() {
    MainActor.assumeIsolated {
        run("SessionLifecycle.singleTransportAndStaleCallbacks") { try testSingleVNCTransport() }
        run("SessionLifecycle.reconnectReusesPasswordAndCancelsQueuedRetry") { try testVNCReconnectCredentials() }
        run("SessionLifecycle.submittedPasswordIsRememberedAfterSuccess") { try testVNCSubmittedPassword() }
        run("SessionLifecycle.latestSavedPasswordWinsAndLockedKeychainFallsBack") { try testVNCLatestSavedPassword() }
        run("SessionLifecycle.networkFailureNeverDeletesPassword") { try testVNCNetworkCredentialSafety() }
        run("SessionLifecycle.rejectedOldPasswordPreservesNewerPassword") { try testVNCRejectedCredentialSafety() }
    }
}

@MainActor
private final class SessionPasswordFixture {
    var value: RFBClient.Credentials?
    var deletions = 0
    var saves = 0
    init(_ password: String? = nil) { value = password.map { .init(username: "", password: $0) } }
    var store: VNCCredentialStore {
        VNCCredentialStore(load: { _ in self.value }, save: { _, c in self.value = c; self.saves += 1; return true },
                           removeIfMatching: { _, c in if self.value == c { self.value = nil; self.deletions += 1 } })
    }
}

@MainActor
private func fixtureSession(_ server: SessionRFBFixture, _ passwords: SessionPasswordFixture) -> VNCSession {
    let session = VNCSession(tunnel: .direct(host: "127.0.0.1", port: server.port), name: "Fixture")
    session.credentialStore = passwords.store
    session.clipboardSyncEnabled = false
    session.remoteAudioEnabled = false
    session.remoteVideoEnabled = false
    return session
}

@MainActor
private func sessionWait(_ timeout: TimeInterval = 2, until predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    return predicate()
}
@MainActor
private func sessionPump(_ seconds: TimeInterval) { _ = sessionWait(seconds) { false } }

@MainActor
private func testSingleVNCTransport() throws {
    let server = try SessionRFBFixture([.silent, .silent]), passwords = SessionPasswordFixture()
    defer { server.stop() }
    let session = fixtureSession(server, passwords)
    defer { session.disconnect() }
    session.connect(); expect(sessionWait { server.connections == 1 })
    for _ in 0..<5 { session.connect() }
    sessionPump(0.05); expect(server.connections == 1)
    // Stop/restart before queued network callbacks can run. The old stream must not clear the new one.
    session.disconnect(); session.connect()
    expect(sessionWait { server.connections == 2 })
    sessionPump(0.05)
    expect(session.state == .connecting && server.activeConnections == 1)
    session.disconnect(); expect(sessionWait { server.activeConnections == 0 })
}

@MainActor
private func testVNCReconnectCredentials() throws {
    let server = try SessionRFBFixture([.acceptAndDrop, .accept]), passwords = SessionPasswordFixture("fixture-pw")
    defer { server.stop() }
    let session = fixtureSession(server, passwords)
    defer { session.disconnect() }
    session.connect()
    expect(sessionWait { if case .reconnecting = session.state { return true }; return false })
    // An immediate user retry supersedes the delayed automatic retry.
    session.connect()
    expect(sessionWait { session.state == .streaming && server.connections == 2 })
    sessionPump(0.65)
    expect(server.connections == 2 && server.activeConnections == 1)
    expect(server.correctResponses == 2 && passwords.deletions == 0 && passwords.value?.password == "fixture-pw")
}

@MainActor
private func testVNCSubmittedPassword() throws {
    let server = try SessionRFBFixture([.accept, .accept]), passwords = SessionPasswordFixture()
    defer { server.stop() }
    let session = fixtureSession(server, passwords)
    defer { session.disconnect() }
    session.connect()
    expect(sessionWait { if case .authenticating = session.state { return true }; return false })
    expect(passwords.value == nil && passwords.saves == 0)
    session.submitPassword(username: "", password: "fixture-pw")
    expect(sessionWait { session.state == .streaming })
    expect(passwords.value?.password == "fixture-pw" && passwords.saves == 1)
    session.disconnect(); session.connect()
    expect(sessionWait { session.state == .streaming && server.connections == 2 })
    expect(server.correctResponses == 2 && passwords.deletions == 0 && passwords.saves == 1)
}

@MainActor
private func testVNCLatestSavedPassword() throws {
    let server = try SessionRFBFixture([.accept]), passwords = SessionPasswordFixture("fixture-pw")
    defer { server.stop() }
    let session = fixtureSession(server, passwords)
    defer { session.disconnect() }
    session.connect(); expect(sessionWait { session.state == .streaming })
    session.disconnect()
    passwords.value = .init(username: "", password: "replacement-pw")
    session.connect(); expect(sessionWait { session.state == .streaming && server.connections == 2 })
    let replacement = RFBCrypto.vncAuthResponse(challenge: Data(0..<16), password: "replacement-pw")
    expect(server.lastResponse == replacement && passwords.saves == 0)
    session.disconnect()
    passwords.value = nil // a locked/unavailable Keychain must not discard the last successful password
    session.connect(); expect(sessionWait { session.state == .streaming && server.connections == 3 })
    expect(server.lastResponse == replacement && passwords.deletions == 0)
}

@MainActor
private func testVNCNetworkCredentialSafety() throws {
    let server = try SessionRFBFixture([.waitForPassword]), passwords = SessionPasswordFixture()
    defer { server.stop() }
    let session = fixtureSession(server, passwords)
    defer { session.disconnect() }
    session.connect()
    expect(sessionWait { if case .authenticating = session.state { return true }; return false })
    // Another setup/window saves the password while this original dialog remains open.
    passwords.value = .init(username: "", password: "new-pw")
    server.closeClients()
    session.submitPassword(username: "", password: "fixture-pw")
    expect(sessionWait { if case .disconnected = session.state { return true }; return false })
    expect(passwords.value?.password == "new-pw" && passwords.deletions == 0 && !session.passwordRejected)
}

@MainActor
private func testVNCRejectedCredentialSafety() throws {
    let server = try SessionRFBFixture([.reject]), passwords = SessionPasswordFixture("fixture-pw")
    defer { server.stop() }
    let session = fixtureSession(server, passwords)
    defer { session.disconnect() }
    session.connect()
    expect(sessionWait { server.correctResponses == 1 })
    // A newly installed desktop changes the stored password before the old response is rejected.
    passwords.value = .init(username: "", password: "replacement-pw")
    server.allowRejection.signal()
    expect(sessionWait { if case .disconnected = session.state { return true }; return false })
    expect(session.passwordRejected && passwords.value?.password == "replacement-pw" && passwords.deletions == 0)

    let second = try SessionRFBFixture([.reject]), old = SessionPasswordFixture("fixture-pw")
    defer { second.stop() }
    let retry = fixtureSession(second, old)
    defer { retry.disconnect() }
    retry.connect(); expect(sessionWait { second.correctResponses == 1 })
    second.allowRejection.signal()
    expect(sessionWait { if case .disconnected = retry.state { return true }; return false })
    expect(retry.passwordRejected && old.value == nil && old.deletions == 1)
}

private final class SessionRFBFixture: @unchecked Sendable {
    enum Behavior { case silent, accept, acceptAndDrop, waitForPassword, reject }
    private let listener: Int32
    private let lock = NSLock()
    private var sockets: Set<Int32> = []
    private var accepted = 0, correct = 0
    private var response: Data?
    private var stopped = false
    private(set) var port = 0
    let allowRejection = DispatchSemaphore(value: 0)
    var connections: Int { lock.withLock { accepted } }
    var activeConnections: Int { lock.withLock { sockets.count } }
    var correctResponses: Int { lock.withLock { correct } }
    var lastResponse: Data? { lock.withLock { response } }

    init(_ behaviors: [Behavior]) throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { close(listener); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        DispatchQueue.global().async { [self] in
            while !lock.withLock({ stopped }) {
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { break }
                let index = lock.withLock { () -> Int in
                    let index = accepted; accepted += 1; sockets.insert(fd); return index
                }
                let behavior = behaviors[min(index, behaviors.count - 1)]
                DispatchQueue.global().async { [self] in serve(fd, behavior) }
            }
        }
    }
    func closeClients() { lock.withLock { for fd in sockets { shutdown(fd, SHUT_RDWR) } } }
    func stop() {
        let first = lock.withLock { () -> Bool in if stopped { return false }; stopped = true; return true }
        guard first else { return }
        allowRejection.signal(); shutdown(listener, SHUT_RDWR); close(listener); closeClients()
    }
    private func read(_ fd: Int32, _ count: Int) -> Data? {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            let n = result.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            guard n > 0 else { return nil }; offset += n
        }
        return result
    }
    @discardableResult private func write(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard n > 0 else { return false }; offset += n
        }
        return true
    }
    private func serve(_ fd: Int32, _ behavior: Behavior) {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        defer { _ = lock.withLock { sockets.remove(fd) }; close(fd) }
        if behavior == .silent { while read(fd, 1) != nil {}; return }
        guard write(fd, Data("RFB 003.008\n".utf8)), read(fd, 12) != nil,
              write(fd, Data([1, 2])), read(fd, 1) == Data([2]) else { return }
        let challenge = Data(0..<16)
        guard write(fd, challenge), let response = read(fd, 16) else { return }
        lock.withLock { self.response = response }
        if response == RFBCrypto.vncAuthResponse(challenge: challenge, password: "fixture-pw") { lock.withLock { correct += 1 } }
        if behavior == .reject {
            _ = allowRejection.wait(timeout: .now() + 3)
            let reason = Data("wrong password".utf8)
            write(fd, Data([0, 0, 0, 1, 0, 0, 0, UInt8(reason.count)]) + reason)
            return
        }
        guard write(fd, Data([0, 0, 0, 0])), read(fd, 1) != nil else { return }
        let name = Data("Fixture".utf8)
        guard write(fd, Data([0, 16, 0, 16]) + Data(repeating: 0, count: 16) + Data([0, 0, 0, UInt8(name.count)]) + name) else { return }
        if behavior == .acceptAndDrop { Thread.sleep(forTimeInterval: 0.08); return }
        while read(fd, 1) != nil {}
    }
}
