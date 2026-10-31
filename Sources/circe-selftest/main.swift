import CryptoKit
import Foundation
import CirceClient
import CirceCore

struct WireTests {
    func roundTrip(_ m: Message) throws -> Message { try Message.decode(m.encoded()) }

    func testInputEventsRoundTrip() throws {
        let events: [InputEvent] = [
            .mouseMove(x: 0.25, y: 0.75),
            .mouseRelative(dx: -3, dy: 4.5),
            .mouseButton(button: .right, down: true, x: 0.1, y: 0.9, clickCount: 2),
            .scroll(dx: 1.5, dy: -12.25, phase: 2, momentumPhase: 0, precise: true),
            .key(keyCode: 0x24, down: true, flags: 0x100000),
            .flagsChanged(keyCode: 0x37, flags: 0x100008),
            .magnify(amount: 0.2, phase: 1),
            .releaseAll,
        ]
        for e in events {
            guard case .input(let back) = try roundTrip(.input(e)) else { fail("kind"); return }
            expect(back == e)
        }
    }

    func testVideoFrameRoundTrip() throws {
        let f = VideoFrame(frameNumber: 42, captureMicros: 123_456_789, flags: VideoFrame.flagKeyframe,
                           parameterSets: [Data([1, 2, 3]), Data([4, 5])], data: Data(repeating: 7, count: 100_000))
        guard case .video(let b) = try roundTrip(.video(f)) else { fail("kind"); return }
        expect(b.frameNumber == 42)
        expect(b.captureMicros == 123_456_789)
        expect(b.isKeyframe)
        expect(b.parameterSets == f.parameterSets)
        expect(b.data == f.data)
    }

    func testControlMessagesRoundTrip() throws {
        let cfg = StreamConfig(displayID: 3, quality: .ultra, maxFPS: 120, audioEnabled: false)
        guard case .configure(let c) = try roundTrip(.configure(cfg)) else { fail("kind"); return }
        expect(c == cfg)
        let clip = ClipboardPayload(items: ["public.utf8-plain-text": Data("hello".utf8)], changeCount: 9)
        guard case .clipboard(let p) = try roundTrip(.clipboard(clip)) else { fail("kind"); return }
        expect(p == clip)
    }

    func testTruncatedAndUnknownAreRejected() {
        expectThrows { try Message.decode(Data([0x10, 0, 0])) }
        expectThrows { try Message.decode(Data([0xEE])) }
        expectThrows { try Message.decode(Data()) }
    }

    func testDeterministicHelloEncoding() throws {
        let h = ClientHello(version: 1, deviceID: "a", deviceName: "b", staticKey: Data([1]), ephemeralKey: Data([2]))
        expect(try Message.clientHello(h).encoded() == Message.clientHello(h).encoded())
    }
}

struct CryptoTests {
    func handshake(clientStatic: Curve25519.KeyAgreement.PrivateKey, hostStatic: Curve25519.KeyAgreement.PrivateKey,
                   hostSeesClientStatic: Data? = nil) throws -> (SessionKeys, SessionKeys) {
        let ce = Curve25519.KeyAgreement.PrivateKey(), he = Curve25519.KeyAgreement.PrivateKey()
        let transcript = Data("transcript".utf8)
        let c = try SessionKeys.derive(isClient: true, localStatic: clientStatic, localEphemeral: ce,
                                       remoteStatic: hostStatic.publicKey.rawRepresentation,
                                       remoteEphemeral: he.publicKey.rawRepresentation, transcript: transcript)
        let h = try SessionKeys.derive(isClient: false, localStatic: hostStatic, localEphemeral: he,
                                       remoteStatic: hostSeesClientStatic ?? clientStatic.publicKey.rawRepresentation,
                                       remoteEphemeral: ce.publicKey.rawRepresentation, transcript: transcript)
        return (c, h)
    }

    func testBothSidesDeriveMatchingKeys() throws {
        let (c, h) = try handshake(clientStatic: .init(), hostStatic: .init())
        var cc = SecureChannel(keys: c), hc = SecureChannel(keys: h)
        for i in 0..<5 {
            let msg = Data("hello \(i)".utf8)
            expect(try hc.open(cc.seal(msg)) == msg)
            expect(try cc.open(hc.seal(msg)) == msg)
        }
    }

    func testImpersonatedClientStaticFails() throws {
        // Host believes the client is someone else -> keys differ -> first frame fails to open.
        let (c, h) = try handshake(clientStatic: .init(), hostStatic: .init(),
                                   hostSeesClientStatic: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        var cc = SecureChannel(keys: c), hc = SecureChannel(keys: h)
        expectThrows { try hc.open(cc.seal(Data("x".utf8))) }
    }

    func testReplayAndTamperRejected() throws {
        let (c, h) = try handshake(clientStatic: .init(), hostStatic: .init())
        var cc = SecureChannel(keys: c), hc = SecureChannel(keys: h)
        let a = try cc.seal(Data("one".utf8))
        _ = try hc.open(a)
        expectThrows { try hc.open(a) }
        var b = try cc.seal(Data("two".utf8))
        b[0] ^= 0xFF
        expectThrows { try hc.open(b) }
    }

    func testSecureEquals() {
        expect(secureEquals("123456", "123456"))
        expect(!secureEquals("123456", "123457"))
        expect(!secureEquals("123456", "12345"))
    }

    func testPINFormat() {
        for _ in 0..<100 {
            let p = generatePairingPIN()
            expect(p.count == 6)
            expect(p.allSatisfy(\.isNumber))
        }
    }
}

struct AddressTests {
    func describe(_ s: String) -> String? {
        guard case let .hostPort(h, p)? = parseEndpoint(s) else { return nil }
        return "\(h):\(p.rawValue)"
    }

    func testParsing() {
        expect(describe("studio.local") == "studio.local:\(circeDefaultPort)")
        expect(describe(" 10.0.0.5:5900 ") == "10.0.0.5:5900")
        expect(describe("circe://mini.local/") == "mini.local:\(circeDefaultPort)")
        expect(describe("[fe80::1]:47801") == "fe80::1:47801")
        expect(describe("fe80::1") != nil)
        expect(describe("") == nil)
        expect(describe("host:notaport") == nil)
    }
}

// Minimal test harness (this toolchain ships without XCTest / Swift Testing macros).
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var current = ""

func expect(_ ok: @autoclosure () throws -> Bool, file: StaticString = #fileID, line: UInt = #line) {
    do {
        if try !ok() { failures += 1; print("  FAIL \(current) at line \(line)") }
    } catch {
        failures += 1; print("  FAIL \(current) at line \(line): threw \(error)")
    }
}

func expectThrows(line: UInt = #line, _ body: () throws -> Any) {
    if (try? body()) != nil { failures += 1; print("  FAIL \(current) at line \(line): expected error") }
}

func fail(_ msg: String, line: UInt = #line) { failures += 1; print("  FAIL \(current) at line \(line): \(msg)") }

func run(_ name: String, _ body: () throws -> Void) {
    current = name
    let before = failures
    do { try body() } catch { failures += 1; print("  FAIL \(name): threw \(error)") }
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

run("WireTests.testInputEventsRoundTrip") { try WireTests().testInputEventsRoundTrip() }
run("WireTests.testVideoFrameRoundTrip") { try WireTests().testVideoFrameRoundTrip() }
run("WireTests.testControlMessagesRoundTrip") { try WireTests().testControlMessagesRoundTrip() }
run("WireTests.testTruncatedAndUnknownAreRejected") { WireTests().testTruncatedAndUnknownAreRejected() }
run("WireTests.testDeterministicHelloEncoding") { try WireTests().testDeterministicHelloEncoding() }
run("CryptoTests.testBothSidesDeriveMatchingKeys") { try CryptoTests().testBothSidesDeriveMatchingKeys() }
run("CryptoTests.testImpersonatedClientStaticFails") { try CryptoTests().testImpersonatedClientStaticFails() }
run("CryptoTests.testReplayAndTamperRejected") { try CryptoTests().testReplayAndTamperRejected() }
run("CryptoTests.testSecureEquals") { CryptoTests().testSecureEquals() }
run("CryptoTests.testPINFormat") { CryptoTests().testPINFormat() }
run("AddressTests.testParsing") { AddressTests().testParsing() }
print(failures == 0 ? "\nAll tests passed." : "\n\(failures) failure(s).")
exit(failures == 0 ? 0 : 1)
