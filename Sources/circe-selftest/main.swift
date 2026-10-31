import CryptoKit
import Foundation
import CirceClient
import CirceCore
@testable import CirceVNC

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

struct BigIntTests {
    func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return d
    }
    func testMontgomeryMatchesPython() {
        let p = BigUInt(bytes: hex("ff26144b98289fcd59a54a7bb1fee08f571242425051c1ccd17f9acae01f5057ca02135e92b1d3f28ede0d7ac3baea9e13deef86ab1031d0f646e1f40a097c976bf46c697d2caf82eeeacbe226e875555790f82ec1d3fcff2a3af4d46b0a18e8830e07bc1e398f1012bd4acefaecbd389be4bcfc49b64a0872e6cc3ababced2057ee05cde00902c77ebff206867347214cdd2055930d6eaf14f4733f3e7d1bfbc7a2ea20b2f14c942e05319acb5c74273f98e2774cbd87ad5c90a9587403e430ec66a78795e761d17731af10506bf2efc6f877186d76b07e881ed162ae2eb1547f15052434b9b5df9e7769b10f4205b4907a70c31012f037b64ce4228c38fb2918f135d25f557203301850c5a38fd547923a736994e3bf911a61dbe22e44158bae97ba94d0eda82f8f6d05584ef8aa38922766581e27a1c08a6a63ec24ede6a46b4cb2424a23d5962217beaddbc496cb8e81973e0becd7b03898d190f9ebdacc0cb1e29c658cda1495e60af593bd04cf0fd630f1f29d0da9953f48f1a09f76b5a170b33839263059f28c105d1fb17c2390c192cfd3ac94af0f21ddb66cad4a268d116ece1738f7d93d9c172411e20b8f6b0d549b6f03675a1600a35a099950d836f675cc81e74ef5e8e25d940ed904759531985d5d9dc9f81818e811892f902bd23f0824128b2f330c5c7fd0a6a3a4506513270e269e0d37f2a74de452e6b439"))
        let b = BigUInt(bytes: hex("0000000000000000000000003571810afc132d0d113db17d30cbc97d0fef792866836886a260cd0b7b45145c1a81682c64e50cad66237a0465e7e4236472f1a38f2c6ec8cc4169a3ae3a2b7fdfe01893f3aed0b6c7ac1491def88334e647cb8f74e69a5d0dd27a65bd628881ad1b72dba7abe1c29e1a8ef4f341e07a83f73f16dbf4a8b2b0c4312d20203626f3fe39c0519088f590fbbd119c1caaf75e8766ed88daf4016b4013ef254b0c4e010c4759482c9cbc43435cc52eae05cf96d0cc5fd4c28c2e7c26847f0316909e3bbbe9eaa8948c893b61867626bb7dbd2d1c9af0153e7c2a26a2c0bd3b1287fff52ddf5d616499c9e25a7605aec6f0245bd86d40fc891b4a6a50df4db4d66a3a47469a4d8cdb305fdd2e16096e36aab0d1bc52d9230d977ee22571594720771f8ca8181166d2287672fdf2022a96fb1a14a0f9e77f1b103cdf1582b0eab477d26415479c65dc9f503f63af83bd0561e6211c70cf49952399c4aaeac137dc76fb0f17a3007e62aa0a1df9fd789c6539382b0537e65affb2297631a992f0ce583505c6af0758d5563dab2cd31ee315128862c33a4fb774eb5248db40af72158370d269a9a5ae658f33fe3b890b93f448b3a5aa3c814f426dcbb394fb36bb2d420f0f88080b10a3d6b2aa05e11ab2715945795e8229451abd81f1d69ed617f5e837d70820fe119a72d174c9df6acc011cdd9474031b"))
        let e = BigUInt(bytes: hex("000f49c81a358ca00d75985d99c94309570dc1951c2442f9298cb3a570ccec31"))
        let r = BigUInt.powMod(b, e, p)
        expect(r.bytes(count: 512) == hex("a05bc9187560420e5e040cc917fc09b96ec3bc09336a01eb4dd6a3f59a571cadc5a109ec01db4aa27157e8ce33b7a527679a9a03b6984fc644375022e1c0595bffaf7dca6464a58860e49542237d26a27cee8f2cc6c835ca11d843e4d71a805a642f194f736b65119402a523edb8a96169c2feddb41b9e2163959ca54b1d61e7d1429fb2ef12fb7d1567d8e08898de6487b493ca36cc88a18ff0374c83787a51fa61570f0e92189bfb6bc83abf6cc6dc9c2980ec99462d1e04bbf5bcb6cb59589719666303c35e7923e9c077858f1f77d0bbf66cd6cb370c76ab8bdcae10ee34f4864fc26b859ab787ac1a8c9e70ef24ef33db8442ec9442e942c750239d00e410e756f407b23e1e0fd26bbbfbc384934b08451c5ffaed5f73a27fadf9cde5f7e97d097b055c245ae165d28743092145a25d7a31fb75c49393e92398844525efee0548e8aac72b16ccfa7fac6cbf4f8627a9a7a9289c865c31fbd988cba0d71aa4d04348089471704484351768bd28fa5364767e7b812a978ce4a490c1a1d858ec1efb3ebf49f98914887afedecb92ce08dfc15577fd57a4c93c5c974a6c4bddce715edf2afff11f7e32ec091f53aef2624d42692e876729224b901841cd57e5fed0fd8a4036d022cc2422be647188dc4d41202aacfe9481594ef1680bd22e580f805e2ff41bcf8b6dd8ad05c7f77e7b030369371cfe6422fb0d396d47e50855"))
        expect(BigUInt.powMod(BigUInt([5]), BigUInt([3]), BigUInt([7])) == BigUInt([6]))
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
run("BigIntTests.testMontgomeryMatchesPython") { BigIntTests().testMontgomeryMatchesPython() }
print(failures == 0 ? "\nAll tests passed." : "\n\(failures) failure(s).")
exit(failures == 0 ? 0 : 1)
