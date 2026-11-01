import CoreMedia
import CryptoKit
import VideoToolbox
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

struct AudioTests {
    func testOpusRoundTrip() {
        guard let enc = OpusEncoder(), let dec = OpusDecoder() else { return fail("no opus codec") }
        // 100 ms of a 440 Hz tone.
        var tone = [Float]()
        for i in 0..<4_800 { let v = Float(sin(Double(i) * 2 * .pi * 440 / 48_000)) * 0.5; tone += [v, v] }
        let packets = enc.encode(interleaved: tone)
        expect(packets.count == 10)
        expect(packets.allSatisfy { $0.count > 10 && $0.count < 1_500 })
        var out = [Float]()
        for p in packets { out += dec.decode(p) ?? [] }
        expect(out.count >= 9_000) // first packet drops the codec's priming samples
        let energy = out.suffix(4_000).reduce(0) { $0 + $1 * $1 } / 4_000
        expect(energy > 0.05 && energy < 0.3) // ~0.125 for a 0.5-amplitude sine
    }
}

struct DatagramTests {
    func frame(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    func testRoundTripNoLoss() {
        for size in [1, 100, 1_150, 1_151, 9_200, 250_000] {
            let payload = frame(size)
            let r = FrameReassembler()
            var got: Data?
            for d in VideoDatagrams.packetize(frameNumber: 5, payload: payload).shuffled() {
                if let f = r.add(d).frames.first { got = f.1 }
            }
            expect(got == payload)
        }
    }

    func testRepairsOneLossPerGroup() {
        let payload = frame(40_000)
        var shards = VideoDatagrams.packetize(frameNumber: 9, payload: payload)
        // Drop one data shard from every group of 8.
        for g in stride(from: 0, to: 35, by: 8).reversed() { shards.remove(at: g + 1) }
        let r = FrameReassembler()
        var got: Data?
        for d in shards { if let f = r.add(d).frames.first { got = f.1 } }
        expect(got == payload)
        expect(r.framesRepaired == 1)
    }

    func testUnrecoverableLossIsReported() {
        let r = FrameReassembler()
        var shards = VideoDatagrams.packetize(frameNumber: 1, payload: frame(20_000))
        shards.removeFirst(2) // two from the same group: parity can't fix it
        for d in shards { expect(r.add(d).frames.isEmpty) }
        var lost = false
        for d in VideoDatagrams.packetize(frameNumber: 2, payload: frame(3_000)) { lost = r.add(d).lost || lost }
        expect(lost)
        expect(r.framesLost == 1)
    }

    func testMalformedShardsAreIgnored() {
        let r = FrameReassembler()
        let shards = VideoDatagrams.packetize(frameNumber: 3, payload: frame(2_000)) // 2 data + 1 parity
        _ = r.add(shards[0])
        var emptyParity = shards[2].prefix(16) // header only, no parity bytes
        _ = r.add(Data(emptyParity))
        emptyParity = Data()
        expect(r.add(Data([1, 2, 3])).frames.isEmpty)
        var lying = shards[1]; lying[13] = 0xFF // payload length field disagrees with the shard
        expect(r.add(lying).frames.isEmpty)
        expect(r.add(shards[1]).frames.first?.1 == frame(2_000))
    }

    func testCipherRoundTripAndReplay() {
        let k = SymmetricKey(size: .bits256)
        var tx = DatagramCipher(key: k), rx = DatagramCipher(key: k)
        let a = tx.seal(Data("a".utf8)), b = tx.seal(Data("b".utf8)), c = tx.seal(Data("c".utf8))
        expect(rx.open(c) == Data("c".utf8))      // out of order is fine
        expect(rx.open(a) == Data("a".utf8))
        expect(rx.open(a) == nil)                 // replay rejected
        expect(rx.open(b) == Data("b".utf8))
        var bad = tx.seal(Data("x".utf8)); bad[10] ^= 1
        expect(rx.open(bad) == nil)               // tamper rejected
    }
}

struct ZlibTests {
    func testInflatesLargePayloadsCompletely() {
        // Mixed-entropy 1 MiB: must come back whole (regression: output was cut at 128 KiB).
        var seed: UInt64 = 42
        let payload = Data((0..<(1 << 20)).map { i -> UInt8 in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return i % 3 == 0 ? UInt8(truncatingIfNeeded: seed >> 56) : UInt8(i % 7)
        })
        let out = try? ZlibStream().inflate(zlibCompress(payload))
        expect(out == payload)
        let text = Data("Grüße ✓".utf8)
        expect((try? ZlibStream().inflate(zlibCompress(text))) == text)
    }
}

struct FLVTests {
    static func tag(_ type: UInt8, _ body: [UInt8], millis: UInt32 = 0) -> [UInt8] {
        let n = body.count
        let head: [UInt8] = [type, UInt8(n >> 16), UInt8(n >> 8 & 255), UInt8(n & 255),
                             UInt8(millis >> 16 & 255), UInt8(millis >> 8 & 255), UInt8(millis & 255), UInt8(millis >> 24),
                             0, 0, 0]
        let total = UInt32(11 + n)
        return head + body + [UInt8(total >> 24), UInt8(total >> 16 & 255), UInt8(total >> 8 & 255), UInt8(total & 255)]
    }

    static let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F, 0xAC]
    static let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]
    static func config(lengthSize: Int) -> [UInt8] {
        [0x17, 0, 0, 0, 0, 1, 0x64, 0x00, 0x1F, 0xFC | UInt8(lengthSize - 1), 0xE1, 0, UInt8(sps.count)] + sps
            + [1, 0, UInt8(pps.count)] + pps
    }
    static let header: [UInt8] = [0x46, 0x4C, 0x56, 1, 1, 0, 0, 0, 9, 0, 0, 0, 0]

    func testSplitsTagsAcrossArbitraryChunks() throws {
        let idr: [UInt8] = [0x17, 1, 0, 0, 0, 0, 0, 0, 3, 0x65, 0x88, 0x84]
        let p: [UInt8] = [0x27, 1, 0, 0, 0, 0, 0, 0, 2, 0x41, 0x9A]
        let audio = Self.tag(8, [0xAF, 1, 9, 9]) // ignored
        let bytes = Self.header + Self.tag(9, Self.config(lengthSize: 4)) + audio
            + Self.tag(9, idr, millis: 16) + Self.tag(9, p, millis: 0x0100_0021)
        var d = FLVDemuxer()
        var out: [FLVDemuxer.Output] = []
        for b in bytes { out += try d.feed(Data([b])) } // worst case: one byte at a time
        expect(out == [.config([Data(Self.sps), Data(Self.pps)]),
                       .frame(keyframe: true, millis: 16, data: Data(idr.dropFirst(5))),
                       .frame(keyframe: false, millis: 0x0100_0021, data: Data(p.dropFirst(5)))])
        var whole = FLVDemuxer()
        expect(try whole.feed(Data(bytes)) == out)
    }

    func testNormalizesShortNALLengths() throws {
        let idr: [UInt8] = [0x17, 1, 0, 0, 0, 0, 3, 0x65, 0x88, 0x84, 0, 1, 0x06]
        var d = FLVDemuxer()
        let out = try d.feed(Data(Self.header + Self.tag(9, Self.config(lengthSize: 2)) + Self.tag(9, idr)))
        expect(out.last == .frame(keyframe: true, millis: 0, data: Data([0, 0, 0, 3, 0x65, 0x88, 0x84, 0, 0, 0, 1, 0x06])))
    }

    func testRejectsGarbageAndOtherCodecs() {
        var d = FLVDemuxer()
        expectThrows { try d.feed(Data("ssh: connect to host\n".utf8)) }
        var hevc = FLVDemuxer()
        expectThrows { try hevc.feed(Data(Self.header + Self.tag(9, [0x1C, 0, 0, 0, 0, 1]))) }
        var huge = FLVDemuxer()
        expectThrows { try huge.feed(Data(Self.header + [9, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0])) }
    }

    func testFramerAttachesParameterSetsToKeyframes() throws {
        var f = LinuxVideoFramer()
        let early = Self.tag(9, [0x27, 1, 0, 0, 0, 0, 0, 0, 1, 0x41]) // before config: dropped
        let idr = Self.tag(9, [0x17, 1, 0, 0, 0, 0, 0, 0, 1, 0x65], millis: 0)
        let p = Self.tag(9, [0x27, 1, 0, 0, 0, 0, 0, 0, 1, 0x41], millis: 17)
        let frames = try f.feed(Data(Self.header + early + Self.tag(9, Self.config(lengthSize: 4)) + idr + p))
        expect(frames.count == 2)
        expect(frames.first?.isKeyframe == true && frames.first?.parameterSets == [Data(Self.sps), Data(Self.pps)])
        expect(frames.last?.isKeyframe == false && frames.last?.parameterSets.isEmpty == true)
        expect(frames.count == 2 && frames[1].captureMicros - frames[0].captureMicros == 17_000)
    }
}

extension FLVTests {
    /// Real H.264 from VideoToolbox → FLV bytes → LinuxVideoFramer → hardware decode → check colours.
    func testDecodesRealH264ThroughFLV() throws {
        let (w, h) = (160, 96)
        var enc: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &enc) == noErr, let enc else {
            return fail("no H.264 encoder")
        }
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        var flv = Self.header
        let colours: [UInt32] = [0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF] // BGRA: blue, green, red
        for (i, c) in colours.enumerated() {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt32.self)
            for k in 0..<(CVPixelBufferGetBytesPerRow(pb!) / 4 * h) { base[k] = c }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            VTCompressionSessionEncodeFrame(enc, imageBuffer: pb!, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 60),
                                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, sample in
                guard let sample, let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
                if i == 0, let atoms = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
                   let avcC = atoms["avcC"] as? Data {
                    flv += Self.tag(9, [0x17, 0, 0, 0, 0] + [UInt8](avcC))
                }
                var len = 0
                var ptr: UnsafeMutablePointer<CChar>?
                CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sample)!, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
                let bytes = [UInt8](UnsafeRawBufferPointer(start: ptr, count: len))
                flv += Self.tag(9, [i == 0 ? 0x17 : 0x27, 1, 0, 0, 0] + bytes, millis: UInt32(i * 16))
            }
            VTCompressionSessionCompleteFrames(enc, untilPresentationTimeStamp: .invalid)
        }
        var framer = LinuxVideoFramer()
        let frames = try framer.feed(Data(flv))
        expect(frames.count == 3 && frames[0].isKeyframe)
        guard let first = frames.first, first.parameterSets.count >= 2 else { return fail("no parameter sets") }
        let centres = Self.decodeCentres(frames, width: w, height: h)
        for (i, want) in colours.enumerated() {
            guard let got = centres[i] else { fail("frame \(i) did not decode"); continue }
            let diff = [16, 8, 0].map { abs(Int((got >> $0) & 0xFF) - Int((want >> $0) & 0xFF)) }.max()!
            if diff > 24 { fail(String(format: "frame %d centre %08X, wanted %08X", i, got, want)) }
        }
    }

    /// Hardware-decodes framed video; returns each frame's centre BGRA pixel (nil = failed to decode).
    static func decodeCentres(_ frames: [VideoFrame], width w: Int, height h: Int) -> [UInt32?] {
        guard let sets = frames.first?.parameterSets, sets.count >= 2 else { return frames.map { _ in nil } }
        var fmt: CMVideoFormatDescription?
        let status = sets[0].withUnsafeBytes { sps in sets[1].withUnsafeBytes { pps in
            let ptrs = [sps.baseAddress!.assumingMemoryBound(to: UInt8.self), pps.baseAddress!.assumingMemoryBound(to: UInt8.self)]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                                                                       parameterSetSizes: [sets[0].count, sets[1].count],
                                                                       nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        } }
        var dec: VTDecompressionSession?
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        guard status == noErr, let fmt,
              VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                           imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &dec) == noErr,
              let dec else { return frames.map { _ in nil } }
        return frames.map { f in
            var block: CMBlockBuffer?
            let data = f.data
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
            data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: data.count) }
            var sample: CMSampleBuffer?
            var size = data.count
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 0,
                                      sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            var got: UInt32?
            VTDecompressionSessionDecodeFrame(dec, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in
                guard st == noErr, let image else { return }
                CVPixelBufferLockBaseAddress(image, .readOnly)
                let row = CVPixelBufferGetBytesPerRow(image) / 4
                got = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt32.self)[h / 2 * row + w / 2]
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
            VTDecompressionSessionWaitForAsynchronousFrames(dec)
            return got
        }
    }
}

struct OggTests {
    static func page(_ packets: [Data], continued: Bool = false, open: Bool = false, seq: UInt32) -> Data {
        var lacing: [UInt8] = []
        for (i, p) in packets.enumerated() {
            var n = p.count
            while n >= 255 { lacing.append(255); n -= 255 }
            if !(open && i == packets.count - 1) { lacing.append(UInt8(n)) } // `open`: last packet continues
        }
        var d = Data("OggS".utf8) + [0, continued ? 1 : 0] + Data(count: 8) + [7, 0, 0, 0]
        d += [UInt8(seq & 255), 0, 0, 0] + Data(count: 4) + [UInt8(lacing.count)] + lacing
        for p in packets { d += p }
        return d
    }

    /// 440 Hz for `seconds` as an Ogg Opus stream (headers + 10 ms packets, 5 per page).
    static func opusStream(seconds: Double) -> Data {
        let enc = OpusEncoder()!
        let n = Int(48_000 * seconds)
        var pcm = [Float](repeating: 0, count: n * 2)
        for i in 0..<n { pcm[i * 2] = sin(2 * .pi * 440 * Float(i) / 48_000) * 0.5; pcm[i * 2 + 1] = pcm[i * 2] }
        let packets = enc.encode(interleaved: pcm)
        var ogg = page([Data("OpusHead".utf8) + Data([1, 2, 0x38, 1, 0x80, 0xBB, 0, 0, 0, 0, 0])], seq: 0)
        ogg += page([Data("OpusTags".utf8) + Data(count: 8)], seq: 1)
        var seq: UInt32 = 2
        for i in stride(from: 0, to: packets.count, by: 5) {
            ogg += page(Array(packets[i..<min(i + 5, packets.count)]), seq: seq); seq += 1
        }
        return ogg
    }

    func testPacketsSpanPagesAndChunks() throws {
        let big = Data((0..<600).map { UInt8($0 % 251) })
        let small = Data([1, 2, 3])
        let bytes = Self.page([small, big.prefix(510)], open: true, seq: 0) + Self.page([big.dropFirst(510), small], continued: true, seq: 1)
        var d = OggDemuxer()
        var out: [Data] = []
        for b in bytes { out += try d.feed(Data([b])) }
        expect(out == [small, big, small])
        var bad = OggDemuxer()
        expectThrows { try bad.feed(Data(count: 40)) }
    }

    func testDetectsPCMAndOpusAndDecodesTone() throws {
        var pcm = RemoteAudioStream()
        expect(try pcm.feed(Data([1, 2, 3])) == [])
        expect(try pcm.feed(Data([4, 5, 6, 7, 8])) == [Data([1, 2, 3, 4, 5, 6, 7, 8])])
        expect(pcm.kind == .pcm)

        var opus = RemoteAudioStream()
        let stream = Self.opusStream(seconds: 0.5)
        var packets: [Data] = []
        for i in stride(from: 0, to: stream.count, by: 97) { packets += try opus.feed(stream.subdata(in: i..<min(i + 97, stream.count))) }
        expect(opus.kind == .opus)
        expect(packets.count >= 45 && !packets.contains { $0.starts(with: Data("Opus".utf8)) })
        let dec = OpusDecoder()!
        let samples = packets.compactMap { dec.decode($0) }.flatMap { $0 }
        let tail = samples.suffix(9600) // skip codec warm-up
        let rms = (tail.reduce(0) { $0 + $1 * $1 } / Float(max(tail.count, 1))).squareRoot()
        expect(rms > 0.2 && rms < 0.5) // a 0.5-amplitude sine has RMS ≈ 0.35
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

if CommandLine.arguments.contains("--session-lifecycle-only") {
    runSessionLifecycleTests()
    runDesktopDiscoveryTests()
    exit(failures == 0 ? 0 : 1)
}

// `circe-selftest --decode-flv PATH WxH`: decode a real helper's stream; prints frames and the last centre pixel.
if let i = CommandLine.arguments.firstIndex(of: "--decode-flv"), i + 2 < CommandLine.arguments.count {
    let wh = CommandLine.arguments[i + 2].split(separator: "x").compactMap { Int($0) }
    var framer = LinuxVideoFramer()
    let frames = (try? framer.feed(try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1])))) ?? []
    let centres = FLVTests.decodeCentres(frames, width: wh[0], height: wh[1])
    let decoded = centres.compactMap { $0 }
    print(String(format: "frames=%d decoded=%d keyframes=%d centre=%06X", frames.count, decoded.count,
                 frames.filter(\.isKeyframe).count, (decoded.last ?? 0) & 0xFFFFFF))
    exit(frames.isEmpty || decoded.count != frames.count ? 1 : 0)
}

// `circe-selftest --decode-ogg PATH`: decode an audio helper's Ogg Opus; prints packets and RMS.
if let i = CommandLine.arguments.firstIndex(of: "--decode-ogg"), i + 1 < CommandLine.arguments.count {
    var stream = RemoteAudioStream()
    let packets = (try? stream.feed(try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1])))) ?? []
    let dec = OpusDecoder()!
    let decoded = packets.compactMap { dec.decode($0) }
    let all = decoded.flatMap { $0 }
    let tail = all.count > 96_000 ? all[(all.count / 2 - 24_000)..<(all.count / 2 + 24_000)] : all[...] // middle 0.5 s
    if CommandLine.arguments.contains("-v") { print(Dictionary(grouping: decoded.map { $0.count / 2 }, by: { $0 }).mapValues(\.count)) }
    let rms = (tail.reduce(0) { $0 + $1 * $1 } / Float(max(tail.count, 1))).squareRoot()
    print(String(format: "kind=%@ packets=%d decoded=%d frames/packet=%d rms=%.3f", "\(stream.kind)", packets.count, decoded.count,
                 (decoded.first?.count ?? 0) / 2, rms))
    exit(stream.kind == .opus && !packets.isEmpty && decoded.count == packets.count ? 0 : 1)
}

// Fixture writer for scripts/test/linux-e2e.sh: `circe-selftest --write-test-ogg PATH`.
if let i = CommandLine.arguments.firstIndex(of: "--write-test-ogg"), i + 1 < CommandLine.arguments.count {
    try! OggTests.opusStream(seconds: 3).write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

struct GCloudTests {
    func testSSHArgumentsPinAccountAndUser() {
        expect(GCloud.sshArgs(instance: "vm", zone: "us-east4-a", project: nil, iap: true)
               == ["compute", "ssh", "vm", "--zone", "us-east4-a", "--quiet", "--tunnel-through-iap"])
        expect(GCloud.sshArgs(instance: "vm", zone: "z", project: "p", iap: false, account: "me@example.org", user: "developer")
               == ["compute", "ssh", "developer@vm", "--zone", "z", "--quiet", "--project", "p", "--account=me@example.org"])
        expect(GCloud.sshArgs(instance: "vm", zone: "z", project: "", iap: false, account: "", user: "")
               == ["compute", "ssh", "vm", "--zone", "z", "--quiet"])
        let tunnel = RFBTunnel.gcloud(instance: "vm", zone: "z", project: "p", useIAP: true, vncPort: 5901, account: "me@example.org", user: "developer")
        let stream = try? tunnel.streamCommand()
        expect(stream?.1.prefix(8) == ["compute", "ssh", "developer@vm", "--zone", "z", "--quiet", "--project", "p"])
        expect(stream?.1.contains("--account=me@example.org") == true && stream?.1.suffix(2) == ["-W", "localhost:5901"])
        // Saved VNC passwords are keyed without account/user, so pinning an account keeps them.
        expect(tunnel.keychainAccount == RFBTunnel.gcloud(instance: "vm", zone: "z", project: "p", useIAP: true, vncPort: 5901).keychainAccount)
    }

    func testActiveAccountReadsGCloudConfiguration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("circe-gcloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("configurations"), withIntermediateDirectories: true)
        try "work\n".write(to: dir.appendingPathComponent("active_config"), atomically: true, encoding: .utf8)
        try "[compute]\naccount = wrong@example.org\n[core]\nproject = p\naccount = me@example.org\n"
            .write(to: dir.appendingPathComponent("configurations/config_work"), atomically: true, encoding: .utf8)
        expect(GCloud.activeAccount(environment: ["CLOUDSDK_CONFIG": dir.path], home: "/nonexistent") == "me@example.org")
        expect(GCloud.activeAccount(environment: ["CLOUDSDK_CONFIG": dir.path, "CLOUDSDK_CORE_ACCOUNT": "env@example.org"], home: "/") == "env@example.org")
        expect(GCloud.activeAccount(environment: ["CLOUDSDK_CONFIG": dir.path, "CLOUDSDK_ACTIVE_CONFIG_NAME": "missing"], home: "/") == nil)
        expect(GCloud.activeAccount(environment: ["CLOUDSDK_CONFIG": dir.path, "CLOUDSDK_ACTIVE_CONFIG_NAME": "../x"], home: "/") == nil)
    }

    func testExplainsWrongAccountAndUser() {
        let unpinned = RFBTunnel.gcloud(instance: "vm", zone: "z", project: "p", useIAP: true, vncPort: 5901)
        let pinned = RFBTunnel.gcloud(instance: "vm", zone: "z", project: "p", useIAP: true, vncPort: 5901, account: "me@example.org", user: nil)
        let lookup = "ERROR: (gcloud.compute.ssh) Could not fetch resource:\n - Required 'compute.instances.get' permission for 'projects/p/zones/z/instances/vm'"
        let wrong = ProcessPipe.explain(lookup, tunnel: unpinned, activeAccount: { "other@example.org" })
        expect(wrong.contains("other@example.org") && wrong.contains("project p") && wrong.contains("Edit connection"))
        expect(ProcessPipe.explain(lookup, tunnel: pinned, activeAccount: { "other@example.org" }).contains("me@example.org"))
        let iap = ProcessPipe.explain("Error while connecting [4033: 'not authorized'].", tunnel: unpinned, activeAccount: { "other@example.org" })
        expect(iap.contains("other@example.org") && iap.contains("Edit connection"))
        let key = ProcessPipe.explain("developer@compute.123456789: Permission denied (publickey).", tunnel: unpinned, activeAccount: { nil })
        expect(key.contains("“developer”") && key.contains("Linux user"))
        let noVNC = "stdio forwarding failed\r\nRecommendation: To check for possible causes...\nERROR: (gcloud.compute.ssh) [/usr/bin/ssh] exited with return code [255]."
        expect(ProcessPipe.explain(noVNC, tunnel: pinned, activeAccount: { nil }).contains("no desktop running on it yet"))
        expect(ProcessPipe.explain("stdio forwarding failed", tunnel: .ssh(destination: "h", port: nil, vncPort: 5901)).contains("no VNC server is running"))
        // SSH (non-gcloud) messages are unchanged.
        expect(ProcessPipe.explain("Permission denied (publickey).", tunnel: .ssh(destination: "h", port: nil, vncPort: 5901)).contains("ssh h"))
    }
}

struct GoogleCloudEngineTests {
    func output(_ stderr: String) -> GoogleCloud.Output { GoogleCloud.Output(status: 1, stdout: "", stderr: stderr, timedOut: false) }

    func testClassifiesFailuresForOneRemedyEach() {
        func kind(_ stderr: String) -> GoogleCloud.Failure { GoogleCloud.classify(output(stderr), account: "me@example.org") }
        expect(kind("ERROR: (gcloud.compute.instances.list) Could not fetch resource:\n - Required 'compute.instances.list' permission for 'projects/p'")
               == .permissionDenied(permission: "compute.instances.list"))
        expect(kind("ERROR: There was a problem refreshing your current auth tokens: ('invalid_grant: Token has been expired or revoked.')") == .signInRequired(account: "me@example.org"))
        expect(kind("ERROR: (gcloud.auth.print-access-token) Reauthentication required.") == .signInRequired(account: "me@example.org"))
        expect(kind("ERROR: There was a problem refreshing your current auth tokens: HTTPSConnectionPool(host='oauth2.googleapis.com'): Max retries exceeded with url: /token (Caused by NewConnectionError: nodename nor servname provided)") == .offline)  // a network failure is not an expired sign-in
        expect(kind("ERROR: gcloud failed to load. You are running gcloud with Python 3.9, which is no longer supported by gcloud.") == .cliMissing)
        expect(kind("ERROR: (gcloud.compute.instances.start) Could not fetch resource:\n - The zone 'projects/p/zones/us-central1-a' does not have enough resources available to fulfill the request. '(resource type:compute)'.") == .capacityUnavailable)
        expect(kind("ZONE_RESOURCE_POOL_EXHAUSTED The zone does not have enough resources") == .capacityUnavailable)
        if case .quotaExceeded = kind("ERROR: Quota 'NVIDIA_L4_GPUS' exceeded.  Limit: 0.0 in region us-central1.") {} else { fail("quota") }
        if case .apiDisabled(let service) = kind("Compute Engine API has not been used in project 123 before or it is disabled. SERVICE_DISABLED compute.googleapis.com") { expect(service == "compute.googleapis.com") } else { fail("api") }
        expect(kind("ERROR: (gcloud.compute.instances.describe) Could not fetch resource:\n - The resource 'projects/p/zones/z/instances/x' was not found") == .notFound)
        expect(GoogleCloud.operationName("Start instance in progress for [https://www.googleapis.com/compute/v1/projects/p/zones/z/operations/operation-1730-abc-def].") == "operation-1730-abc-def")
        expect(GoogleCloud.operationName("[{\"name\": \"operation-99-x\"}]") == "operation-99-x")
    }

    func testMetadataSuggestsUsersWithoutGuessing() {
        let key = "ssh-rsa AAAAB3mine me@mac"
        let users = GoogleCloud.suggestedUsers(metadata: [("workstation-user", "developer"), ("ssh-keys", "alice:ssh-ed25519 AAAAother alice\nbob:ssh-rsa AAAAB3mine bob"),
                                                          ("startup-script", "rm -rf /"), ("workstation-user", "../etc")], localKey: key)
        expect(users == ["developer", "bob", "alice"])  // Explicit hint, then the owner of this Mac's key, then others; invalid names dropped
        let parsed = try? GoogleCloud.parseInstances(#"[{"id":"42","name":"vm","zone":"https://x/zones/us-east4-a","status":"TERMINATED","machineType":"https://x/machineTypes/g2-standard-8","guestAccelerators":[{"acceleratorType":"https://x/acceleratorTypes/nvidia-l4","acceleratorCount":1}],"metadata":{"items":[{"key":"enable-oslogin","value":"TRUE"}]}}]"#)
        expect(parsed?.first?.gpu == "NVIDIA L4" && parsed?.first?.zone == "us-east4-a" && parsed?.first?.osLogin == true && parsed?.first?.canStart == true)
        expect(parsed?.first?.hostKeyAlias(project: "p") == "circe-gce-42")
        expect(GoogleCloud.Instance(id: nil, name: "vm", zone: "z", status: "RUNNING", machineType: "", gpu: nil, hasExternalIP: false, suggestedUsers: [], osLogin: nil)
               .hostKeyAlias(project: "p") == "circe-gce-p-z-vm")
    }

    func testIAPTransportIsPinnedAndIgnoresUserConfig() throws {
        let tunnel = RFBTunnel.iap(instance: "vm", zone: "us-east4-a", project: "p", account: "me@example.org", user: "developer", hostKeyAlias: "circe-gce-42", vncPort: 5900)
        let (exe, args) = try tunnel.streamCommand()
        expect(exe.path == "/usr/bin/ssh" && args.prefix(2) == ["-F", "/dev/null"])  // The user's ssh config must not apply
        let proxy = args.first { $0.hasPrefix("ProxyCommand=") } ?? ""
        expect(proxy.contains("'start-iap-tunnel'") && proxy.contains("'--account=me@example.org'") && proxy.contains("'--project=p'") && proxy.contains("'--zone=us-east4-a'"))
        let knownHosts = args.first { $0.hasPrefix("UserKnownHostsFile=") } ?? ""
        expect(knownHosts.hasPrefix("UserKnownHostsFile=\"") && knownHosts.hasSuffix("known_hosts\""))  // Quoted: Application Support has a space
        expect(args.contains("HostKeyAlias=circe-gce-42") && args.contains("IdentitiesOnly=yes") && args.suffix(3) == ["-W", "localhost:5900", "circe-gce-42"])
        expect(args.contains("-l") && args[args.firstIndex(of: "-l")! + 1] == "developer")
        expect(tunnel.keychainAccount == RFBTunnel.gcloud(instance: "vm", zone: "us-east4-a", project: "p", useIAP: true, vncPort: 5900).keychainAccount)  // saved VNC passwords carry over
        let remote = try tunnel.remoteCommand("id -un")
        expect(remote?.1.suffix(3) == ["-T", "circe-gce-42", "exec /bin/sh -c 'id -un'"])  // POSIX sh whatever the login shell
        // The wrapped command means exactly what it says once a shell runs it (quotes, $, and all).
        let tricky = #"printf '%s|' "it's" '$HOME' "a b""#
        let shell = Process(); shell.executableURL = URL(fileURLWithPath: "/bin/sh"); shell.arguments = ["-c", RFBTunnel.posix(tricky)]
        let out = Pipe(); shell.standardOutput = out; try shell.run(); shell.waitUntilExit()
        expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "it's|$HOME|a b|")
        let start = LinuxSetup.desktopStartCommand(port: 5901)
        expect(start.contains("/dev/tcp/127.0.0.1/5901") && start.contains("echo CIRCE_DESKTOP_READY; exec cat >/dev/null"))
        let quoted = try IAPSSH.proxyCommand(instance: "vm", zone: "z", project: "p", account: "a@b.c")
        expect(!quoted.contains("%") || quoted.contains("%%"))  // ssh %-tokens are escaped
    }

    func testProbeDecodingKeepsOnlyRealDesktops() throws {
        let json = #"{"user":"developer","os":{"id":"omarchy","like":"arch","name":"Omarchy"},"packageManager":"pacman","sudo":"password","adminGroup":true,"systemd":true,"ffmpeg":true,"circe":{"installed":false,"display":null,"running":false},"vnc":[{"port":5900,"display":0,"address":"127.0.0.1","loopback":true,"rfb":true,"process":"wayvnc"},{"port":5905,"display":5,"address":"0.0.0.0","loopback":false,"rfb":true,"process":"x11vnc"},{"port":5910,"display":10,"address":"127.0.0.1","loopback":true,"rfb":false,"process":"other"}],"sessions":["Hyprland"]}"#
        let probe = try JSONDecoder().decode(LinuxSetup.Probe.self, from: Data(json.utf8))
        expect(probe.existingDesktops.map(\.port) == [5900])  // Public listeners and non-VNC ports aren't offered
        expect(probe.canInstall && probe.needsSudoPassword)
        expect(probe.systemDesktop == nil && probe.circe.current == nil && probe.circe.shared == nil)  // older scripts
        let gnome = #"{"user":"u","os":{"id":"ubuntu","like":"debian","name":"Ubuntu"},"packageManager":"apt","sudo":"password","adminGroup":true,"systemd":true,"ffmpeg":false,"circe":{"installed":true,"display":1,"running":true,"current":false,"shared":"chrome-remote-desktop"},"vnc":[],"sessions":[],"systemDesktop":{"id":"ubuntu","name":"Ubuntu"}}"#
        let own = try JSONDecoder().decode(LinuxSetup.Probe.self, from: Data(gnome.utf8))
        expect(own.systemDesktop?.name == "Ubuntu" && own.circe.current == false && own.circe.shared == "chrome-remote-desktop")
        let result = try JSONDecoder().decode(LinuxSetup.Report.self, from: Data(#"{"display":1,"password":null,"audio":true,"persistent":true,"withoutAdmin":true,"sharedSession":"chrome-remote-desktop"}"#.utf8))
        expect(result.sharedSession == "chrome-remote-desktop")
        // Audio and microphone follow a shared session's own sound server (Chrome Remote Desktop runs one).
        expect(VNCSession.remoteAudioCommand(display: 1).contains("circe/desktop.env") && VNCSession.remoteMicrophoneCommand.contains("circe/desktop.env"))
        expect(VNCSession.remoteClipboardCommand(display: 3).hasSuffix("--display 3") && VNCSession.remoteClipboardCommand(display: 3).contains("exit 69"))
        let wrapper = LinuxSetup.remoteWrapper(arguments: ["--display", "1"])
        expect(wrapper.hasPrefix("set +x; ") && wrapper.contains("IFS= read -r p") && wrapper.contains("3<&0 </dev/null") && wrapper.contains("'--display' '1'") && !wrapper.contains("$p\" bash"))  // password line first, handed over on fd 3 only
    }

    func testInstallerRefusesUnsafeArchives() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("circe-installer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/inner"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("src/inner/file"), atomically: true, encoding: .utf8)
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", dir.appendingPathComponent("evil.tar.gz").path, "-C", dir.appendingPathComponent("src/inner").path, "--options", "", "-s", ",^,../,", "file"]
        try tar.run(); tar.waitUntilExit()
        var refused = false
        do { try GoogleCloudInstaller.extract(dir.appendingPathComponent("evil.tar.gz"), into: dir.appendingPathComponent("out")) } catch { refused = true }
        expect(refused)  // Archives with ../ paths are refused
        expect(GoogleCloudInstaller.sdk.url.absoluteString.contains(GoogleCloudInstaller.sdkVersion) && GoogleCloudInstaller.sdk.sha256.count == 64)
        expect(GoogleCloudInstaller.python.url.absoluteString.contains("%2B") && GoogleCloudInstaller.python.sha256.count == 64)
    }
}

struct GoogleCloudReviewTests {
    func testSignInPageKeepsEncodingAndAddsHint() {
        let printed = "Go to the following link in your browser:\n\n    https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=32555940559.apps.googleusercontent.com&redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F&scope=openid+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform&state=AbC&access_type=offline\n"
        let url = GoogleCloud.signInPage(in: printed, hint: "first.last+vm@example.org")!.absoluteString
        expect(url.hasPrefix("https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=32555940559.apps.googleusercontent.com&redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F&scope=openid+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform&state=AbC&access_type=offline"))
        expect(url.hasSuffix("&login_hint=first.last%2Bvm%40example.org"))
        expect(GoogleCloud.signInPage(in: printed, hint: nil)!.absoluteString.contains("login_hint") == false)
        expect(GoogleCloud.signInPage(in: "https://accounts.google.com/x?login_hint=a%40b.co\n", hint: "casey@example.org")!.absoluteString == "https://accounts.google.com/x?login_hint=a%40b.co")
        expect(GoogleCloud.signInPage(in: "https://accounts.google.com.evil.example/x\n", hint: nil) == nil)
        expect(GoogleCloud.signInPage(in: "nothing here", hint: "alex@example.org") == nil)
        // Output arrives in pieces: no prefix of the line may be taken for the whole link.
        let line = printed.components(separatedBy: "\n").first { $0.contains("https://") }!.trimmingCharacters(in: .whitespaces)
        for cut in 1..<line.count { expect(GoogleCloud.signInPage(in: String(line.prefix(cut)), hint: nil) == nil) }
        expect(GoogleCloud.signInPage(in: line + "\n", hint: nil)?.absoluteString == line)
    }

    func testOnceIsClaimedExactlyOnceAcrossThreads() {
        for _ in 0..<200 {
            let once = GoogleCloud.Once(), wins = GoogleCloud.Collected()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in if once.claim() { wins.append(out: Data("x".utf8)) } }
            expect(wins.stdout == "x")
            expect(once.done)
        }
    }

    func testSSHConfigLoginsAreReadNotRun() {
        let config = """
        Host omarchy-agent
          HostName omarchy-agent
          User developer
          IdentityFile ~/.ssh/agent_machine_ed25519
          ProxyCommand gcloud compute start-iap-tunnel %h 22 --listen-on-stdin
        Host example-vm
            HostName cloud-developer-workstation
            User developer_example_org
            IdentityFile /example-home/developer/.ssh/google_compute_engine
        Host *
          User nobody
        Match exec "rm -rf /"
          User evil
        """
        expect(GoogleCloud.sshConfigLogins(instance: "omarchy-agent", configText: config) == [.init(user: "developer", identityFile: "~/.ssh/agent_machine_ed25519")])
        expect(GoogleCloud.sshConfigLogins(instance: "cloud-developer-workstation", configText: config).first?.user == "developer_example_org")
        expect(GoogleCloud.sshConfigLogins(instance: "unknown", configText: config).isEmpty)  // wildcards and Match never count
    }

    func testCirceConfigurationKeepsOnlyNetworkSettings() {
        let active = "[core]\naccount = other@example.org\nproject = wrong\ncustom_ca_certs_file = /etc/example-ca.pem\n[auth]\nimpersonate_service_account = service-account@example.invalid\naccess_token_file = /tmp/token\n[proxy]\ntype = http\naddress = proxy.example.org\nport = 3128\n[compute]\nzone = us-east1-b\n"
        let ours = GoogleCloud.configuration(from: active)
        expect(ours.contains("custom_ca_certs_file = /etc/example-ca.pem") && ours.contains("[proxy]") && ours.contains("address = proxy.example.org"))
        expect(!ours.contains("account") && !ours.contains("impersonate") && !ours.contains("access_token_file") && !ours.contains("project") && !ours.contains("zone"))
        let env = GoogleCloud.environment()
        expect(env["CLOUDSDK_ACTIVE_CONFIG_NAME"] == GoogleCloud.configurationName && env["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"] == nil)
        expect(GoogleCloud.environment(circeConfiguration: false)["CLOUDSDK_ACTIVE_CONFIG_NAME"] != GoogleCloud.configurationName)
    }

    func testKeyFileAndHostKeyConflicts() throws {
        let tunnel = RFBTunnel.iap(instance: "vm", zone: "z", project: "p", account: "alex@example.org", user: "developer", hostKeyAlias: "circe-gce-1", vncPort: 5900, identity: "~/.ssh/agent_key")
        let args = try tunnel.streamCommand().1
        expect(args[args.firstIndex(of: "-i")! + 1] == ("~/.ssh/agent_key" as NSString).expandingTildeInPath)
        let proxy = args.first { $0.hasPrefix("ProxyCommand=") } ?? ""
        expect(proxy.hasPrefix("ProxyCommand=/usr/bin/env CLOUDSDK_ACTIVE_CONFIG_NAME=circe-app "))  // works under any login shell's `exec`
        let known = "circe-gce-1 ssh-ed25519 AAAAold\nother ssh-rsa AAAAx\n"
        expect(IAPSSH.pinnedKeys(alias: "circe-gce-1", in: known) == ["ssh-ed25519 AAAAold"])
        expect(!IAPSSH.agree(["ssh-rsa A", "ssh-ed25519 B"], ["ssh-rsa A", "ssh-ed25519 C"]))  // overlap can't hide a conflict
        expect(IAPSSH.agree(["ssh-rsa A", "ssh-ed25519 B"], ["ssh-ed25519 B"]) && !IAPSSH.agree(["ssh-rsa A"], ["ssh-ed25519 B"]))
    }
}

struct MicrophoneTests {
    func testRemoteMicrophoneIsPrivateAndCleansUp() {
        let c = VNCSession.remoteMicrophoneCommand
        expect(c.contains("module-null-sink sink_name=$s") && c.contains("module-remap-source master=$s.monitor source_name=$m"))
        expect(c.contains("prev=$(pactl get-default-source") && c.contains("pactl set-default-source \"$prev\"") && c.contains("trap cleanup EXIT"))
        expect(c.contains("pactl unload-module") && c.contains("pacat --playback --device=\"$s\" --format=s16le --rate=48000 --channels=1"))
        expect(!c.contains("sudo") && !c.contains("exec pacat"))  // no root; not exec'd, so the cleanup trap runs
    }
}
run("MicrophoneTests.testRemoteMicrophoneIsPrivateAndCleansUp") { MicrophoneTests().testRemoteMicrophoneIsPrivateAndCleansUp() }
runMicrophoneReviewTests()
runSessionLifecycleTests()
runDesktopDiscoveryTests()
struct DesktopLeaseTests {
    /// A fake ssh (CIRCE_SSH_PATH) that runs `body` as /bin/sh, ignoring ssh's own arguments.
    func withFakeSSH(_ body: String, _ test: (RFBTunnel) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("circe-lease-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("CIRCE_SSH_PATH") }
        let script = dir.appendingPathComponent("ssh")
        try? ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        setenv("CIRCE_SSH_PATH", script.path, 1)
        try test(.ssh(destination: "u@h", port: nil, vncPort: 5901))
    }

    func testReadyLineIsRequired() {
        withFakeSSH("exec 1>&-; sleep 3") { tunnel in   // output ends, session still alive: not READY
            let started = Date()
            guard case .failure = LinuxSetup.startDesktop(tunnel: tunnel, cancel: GoogleCloud.CancelToken(), timeout: 10) else { return expect(false) }
            expect(Date().timeIntervalSince(started) < 5)
        }
        withFakeSSH("echo xCIRCE_DESKTOP_READYx; exec cat >/dev/null") { tunnel in   // not the exact line
            guard case .failure = LinuxSetup.startDesktop(tunnel: tunnel, cancel: GoogleCloud.CancelToken(), timeout: 2) else { return expect(false) }
        }
        withFakeSSH("echo CIRCE_DESKTOP_READY; exec cat >/dev/null") { tunnel in
            guard case let .success(lease) = LinuxSetup.startDesktop(tunnel: tunnel, cancel: GoogleCloud.CancelToken(), timeout: 10) else { return expect(false) }
            expect(lease.isActive)
            lease.end()
            let deadline = Date().addingTimeInterval(3)
            while lease.isActive && Date() < deadline { usleep(20_000) }
            expect(!lease.isActive)
        }
    }

    func testCancelledWorkNeverReachesTheComputer() {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("circe-launched-\(UUID().uuidString)")
        withFakeSSH("touch '\(marker.path)'; echo CIRCE_DESKTOP_READY; exec cat >/dev/null") { tunnel in
            let cancel = GoogleCloud.CancelToken(); cancel.cancel()
            guard case .failure = LinuxSetup.startDesktop(tunnel: tunnel, cancel: cancel) else { return expect(false) }
            usleep(300_000)
            expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testLostLeaseIsReported() {
        withFakeSSH("echo CIRCE_DESKTOP_READY; sleep 0.5; exit 0") { tunnel in
            guard case let .success(lease) = LinuxSetup.startDesktop(tunnel: tunnel, cancel: GoogleCloud.CancelToken(), timeout: 10) else { return expect(false) }
            let lost = DispatchSemaphore(value: 0)
            lease.onLost { lost.signal() }
            expect(lost.wait(timeout: .now() + 5) == .success)
        }
        withFakeSSH("echo CIRCE_DESKTOP_READY; exec cat >/dev/null") { tunnel in   // ending it on purpose isn't "lost"
            guard case let .success(lease) = LinuxSetup.startDesktop(tunnel: tunnel, cancel: GoogleCloud.CancelToken(), timeout: 10) else { return expect(false) }
            let lost = DispatchSemaphore(value: 0)
            lease.onLost { lost.signal() }
            lease.end()
            expect(lost.wait(timeout: .now() + 1.5) == .timedOut)
        }
    }
}
run("DesktopLeaseTests.testReadyLineIsRequired") { DesktopLeaseTests().testReadyLineIsRequired() }
run("DesktopLeaseTests.testCancelledWorkNeverReachesTheComputer") { DesktopLeaseTests().testCancelledWorkNeverReachesTheComputer() }
run("DesktopLeaseTests.testLostLeaseIsReported") { DesktopLeaseTests().testLostLeaseIsReported() }
run("MicrophoneTests.testRemoteCommandsFindPrivateTools") {
    // Desktops set up without administrator access keep pactl/parec/pacat in Circe's private folder.
    for c in [VNCSession.remoteAudioCommand(display: 1), VNCSession.remoteMicrophoneCommand] {
        expect(c.hasPrefix("[ -r \"$HOME/.config/circe/prefix.env\" ] && . \"$HOME/.config/circe/prefix.env\";"))
    }
}
run("GoogleCloudReviewTests.testSSHConfigLoginsAreReadNotRun") { GoogleCloudReviewTests().testSSHConfigLoginsAreReadNotRun() }
run("GoogleCloudReviewTests.testCirceConfigurationKeepsOnlyNetworkSettings") { GoogleCloudReviewTests().testCirceConfigurationKeepsOnlyNetworkSettings() }
run("GoogleCloudReviewTests.testKeyFileAndHostKeyConflicts") { try GoogleCloudReviewTests().testKeyFileAndHostKeyConflicts() }
run("GoogleCloudReviewTests.testSignInPageKeepsEncodingAndAddsHint") { GoogleCloudReviewTests().testSignInPageKeepsEncodingAndAddsHint() }
run("GoogleCloudReviewTests.testOnceIsClaimedExactlyOnceAcrossThreads") { GoogleCloudReviewTests().testOnceIsClaimedExactlyOnceAcrossThreads() }
run("GoogleCloudEngineTests.testClassifiesFailuresForOneRemedyEach") { GoogleCloudEngineTests().testClassifiesFailuresForOneRemedyEach() }
run("GoogleCloudEngineTests.testMetadataSuggestsUsersWithoutGuessing") { GoogleCloudEngineTests().testMetadataSuggestsUsersWithoutGuessing() }
run("GoogleCloudEngineTests.testIAPTransportIsPinnedAndIgnoresUserConfig") { try GoogleCloudEngineTests().testIAPTransportIsPinnedAndIgnoresUserConfig() }
run("GoogleCloudEngineTests.testProbeDecodingKeepsOnlyRealDesktops") { try GoogleCloudEngineTests().testProbeDecodingKeepsOnlyRealDesktops() }
run("GoogleCloudEngineTests.testInstallerRefusesUnsafeArchives") { try GoogleCloudEngineTests().testInstallerRefusesUnsafeArchives() }
run("GCloudTests.testSSHArgumentsPinAccountAndUser") { GCloudTests().testSSHArgumentsPinAccountAndUser() }
run("GCloudTests.testActiveAccountReadsGCloudConfiguration") { try GCloudTests().testActiveAccountReadsGCloudConfiguration() }
run("GCloudTests.testExplainsWrongAccountAndUser") { GCloudTests().testExplainsWrongAccountAndUser() }
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
run("AudioTests.testOpusRoundTrip") { AudioTests().testOpusRoundTrip() }
run("DatagramTests.testRoundTripNoLoss") { DatagramTests().testRoundTripNoLoss() }
run("DatagramTests.testRepairsOneLossPerGroup") { DatagramTests().testRepairsOneLossPerGroup() }
run("DatagramTests.testUnrecoverableLossIsReported") { DatagramTests().testUnrecoverableLossIsReported() }
run("DatagramTests.testMalformedShardsAreIgnored") { DatagramTests().testMalformedShardsAreIgnored() }
run("DatagramTests.testCipherRoundTripAndReplay") { DatagramTests().testCipherRoundTripAndReplay() }
run("ZlibTests.testInflatesLargePayloadsCompletely") { ZlibTests().testInflatesLargePayloadsCompletely() }
run("FLVTests.testSplitsTagsAcrossArbitraryChunks") { try FLVTests().testSplitsTagsAcrossArbitraryChunks() }
run("FLVTests.testNormalizesShortNALLengths") { try FLVTests().testNormalizesShortNALLengths() }
run("FLVTests.testRejectsGarbageAndOtherCodecs") { FLVTests().testRejectsGarbageAndOtherCodecs() }
run("FLVTests.testFramerAttachesParameterSetsToKeyframes") { try FLVTests().testFramerAttachesParameterSetsToKeyframes() }
run("FLVTests.testDecodesRealH264ThroughFLV") { try FLVTests().testDecodesRealH264ThroughFLV() }
run("OggTests.testPacketsSpanPagesAndChunks") { try OggTests().testPacketsSpanPagesAndChunks() }
run("OggTests.testDetectsPCMAndOpusAndDecodesTone") { try OggTests().testDetectsPCMAndOpusAndDecodesTone() }
print(failures == 0 ? "\nAll tests passed." : "\n\(failures) failure(s).")
exit(failures == 0 ? 0 : 1)
