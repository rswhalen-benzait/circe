import AVFoundation
import Foundation
import Darwin
import CirceClient
@testable import CirceVNC

/// Add `runMicrophoneReviewTests()` to main.swift. No microphone hardware or permissions are used.
func runMicrophoneReviewTests() {
    MainActor.assumeIsolated {
        run("MicrophoneReviewTests.frameAlignedBoundedQueue") { testMicrophoneBoundedQueue() }
        run("MicrophoneReviewTests.nonblockingWriterAndClosedPipe") { try testMicrophoneWriter() }
        run("MicrophoneReviewTests.resamplingAndFormatChange") { try testMicrophoneConversion() }
        run("MicrophoneReviewTests.remoteReadinessProtocol") { testMicrophoneReadiness() }
        run("MicrophoneReviewTests.explicitOptInBeforePermission") {
            let session = VNCSession(tunnel: .ssh(destination: "fixture", port: nil, vncPort: 5901), name: "Fixture")
            expect(!session.microphoneEnabled && !session.microphoneActive)
            session.microphoneEnabled = true // idle: never prompts or starts SSH
            expect(!session.microphoneActive)
            session.microphoneEnabled = false
            expect(!session.microphoneActive && session.microphoneProblem == nil)
        }
        run("MicrophoneReviewTests.remoteIsolationAndCleanup") { try testMicrophoneRemoteShell() }
        run("MicrophoneReviewTests.standalonePrivacyAndStatus") { try testMicrophoneStandaloneUI() }
    }
}

private func testMicrophoneBoundedQueue() {
    var q = MicrophonePCMBuffer()
    expect(q.capacity == 19_200)
    for value in 0..<30 { q.append(Data(repeating: UInt8(value), count: 1_920), now: 1) }
    expect(q.count == q.capacity)
    expect(q.peek(maximum: 1_920, now: 1) == Data(repeating: 20, count: 1_920), file: #fileID)
    q.consume(512)
    expect(q.peek(maximum: 512, now: 1).count == 512 && q.count.isMultiple(of: 2))
    q.append(Data([1, 2, 3]), now: 1) // malformed partial PCM frame is rejected
    expect(q.count == 19_200 - 512)
    expect(q.peek(maximum: 512, now: 1.21).isEmpty && q.count == 0)
    q.append(Data(repeating: 7, count: 30_000), now: 2)
    expect(q.count == q.capacity && q.peek(maximum: 513, now: 2).count == 512)
    q.removeAll(); expect(q.count == 0)
}

private final class MicrophoneTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private func testMicrophoneWriter() throws {
    let pipe = Pipe(), sent = DispatchSemaphore(value: 0), errors = MicrophoneTestCounter()
    let writer = try MicrophonePCMWriter(handle: pipe.fileHandleForWriting, onFirstWrite: { sent.signal() }, onError: { errors.increment() })
    writer.enqueue(Data(repeating: 0x19, count: 1_920))
    expect(sent.wait(timeout: .now() + 2) == .success)
    expect(writer.hasWritten)
    // Fill the unread OS pipe and keep producing: queued application PCM must stay bounded.
    for _ in 0..<5_000 { writer.enqueue(Data(repeating: 0x20, count: 1_920)) }
    expect(writer.pendingBytes <= 19_200)
    let start = ProcessInfo.processInfo.systemUptime
    writer.close()
    expect(ProcessInfo.processInfo.systemUptime - start < 1)
    writer.enqueue(Data(repeating: 0, count: 1_920))
    expect(writer.pendingBytes == 0 && errors.count == 0)
    try pipe.fileHandleForReading.close()

    let broken = Pipe(), failed = DispatchSemaphore(value: 0)
    try broken.fileHandleForReading.close()
    let closedWriter = try MicrophonePCMWriter(handle: broken.fileHandleForWriting, onFirstWrite: {}, onError: { failed.signal() })
    closedWriter.enqueue(Data([0, 0]))
    expect(failed.wait(timeout: .now() + 2) == .success, file: #fileID) // EPIPE, never SIGPIPE
    closedWriter.close()
}

private func testMicrophoneConversion() throws {
    for rate in [8_000.0, 16_000, 24_000, 44_100, 48_000, 96_000] {
        for channels: AVAudioChannelCount in [1, 2] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
            let converter = try MicrophonePCMConverter(inputFormat: format)
            let frames = AVAudioFrameCount(rate / 50)
            var output = Data()
            for chunk in 0..<100 {
                let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                input.frameLength = frames
                for channel in 0..<Int(channels) {
                    for frame in 0..<Int(frames) {
                        let n = chunk * Int(frames) + frame
                        input.floatChannelData![channel][frame] = Float(sin(2 * .pi * 440 * Double(n) / rate) * 12_000 / 32_768)
                    }
                }
                output.append(try converter.convert(input))
            }
            expect(abs(output.count / 2 - 96_000) <= 2)
            var sum = 0.0
            output.withUnsafeBytes { bytes in
                for i in stride(from: 0, to: bytes.count, by: 2) {
                    let sample = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: Int16.self)))
                    sum += sample * sample
                }
            }
            let rms = sqrt(sum / Double(output.count / 2))
            expect((8_300...8_650).contains(rms))
            let changed = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate + 100, channels: channels, interleaved: false)!
            let wrong = AVAudioPCMBuffer(pcmFormat: changed, frameCapacity: 32)!
            wrong.frameLength = 32
            expectThrows { try converter.convert(wrong) }
        }
    }
}

private func testMicrophoneReadiness() {
    let ready = #"CIRCE_MIC_READY {"pid":123,"source":"circe_mic_123","sink":"circe_mic_feed_123"}"#
    expect(MicrophoneRemoteStatus(stderr: "warning\n" + ready).ready)
    expect(!MicrophoneRemoteStatus(stderr: String(ready.dropLast())).ready)
    expect(!MicrophoneRemoteStatus(stderr: ready.replacingOccurrences(of: "circe_mic_123", with: "circe_mic_124")).ready)
    expect(!MicrophoneRemoteStatus(stderr: "log: " + ready).ready)
    let failed = MicrophoneRemoteStatus(stderr: ready + "\nCIRCE_MIC_ERROR source_create\n")
    expect(!failed.ready && failed.error == "source_create" && MicrophoneRemoteStatus.permanentErrors.contains("source_create"))
    expect(!failed.message.contains("CIRCE_MIC_ERROR"))
}

private func microphoneRun(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 60) throws -> (Int32, String) {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.environment = environment; process.standardOutput = output; process.standardError = output
    let lock = NSLock()
    nonisolated(unsafe) var collected = Data()
    output.fileHandleForReading.readabilityHandler = { h in
        let data = h.availableData
        if !data.isEmpty { lock.withLock { collected.append(data) } }
    }
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    guard finished.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        _ = finished.wait(timeout: .now() + 2)
        output.fileHandleForReading.readabilityHandler = nil
        throw NSError(domain: "MicrophoneReviewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture timed out"])
    }
    Thread.sleep(forTimeInterval: 0.05)
    output.fileHandleForReading.readabilityHandler = nil
    return (process.terminationStatus, lock.withLock { String(decoding: collected, as: UTF8.self) })
}

private func testMicrophoneRemoteShell() throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("circe-mic-review-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let command = work.appendingPathComponent("mic-command-runtime.sh")
    try VNCSession.remoteMicrophoneCommand.write(to: command, atomically: true, encoding: .utf8)
    let script = work.appendingPathComponent("mock.py")
    try microphoneMockScript.write(to: script, atomically: true, encoding: .utf8)
    let (status, text) = try microphoneRun("/usr/bin/python3", [script.path], timeout: 45)
    if status != 0 { fail(text) }
    expect(status == 0 && text.components(separatedBy: "PASS:").count == 7)
}

private func testMicrophoneStandaloneUI() throws {
    // The selftest target intentionally has no CirceUI dependency. Compile its actual standalone
    // sources in a temporary directory, preserving that architectural constraint while testing privacy.
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("circe-mic-ui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let fixture = work.appendingPathComponent("Privacy.swift"), binary = work.appendingPathComponent("check")
    try microphonePrivacyScript.replacingOccurrences(of: "MICROPHONE_ENTRY", with: "@" + "main").write(to: fixture, atomically: true, encoding: .utf8)
    let sources = try FileManager.default.contentsOfDirectory(at: repo.appendingPathComponent("Sources/CirceUI"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "EngineBridge.swift" }.sorted { $0.path < $1.path }
    let arguments = ["swiftc", "-parse-as-library", "-swift-version", "5", "-module-cache-path", work.appendingPathComponent("modules").path]
        + sources.map(\.path) + [fixture.path, "-o", binary.path]
    let built = try microphoneRun("/usr/bin/xcrun", arguments, environment: ProcessInfo.processInfo.environment, timeout: 120)
    if built.0 != 0 { fail(built.1); return }
    let checked = try microphoneRun(binary.path, [], environment: ProcessInfo.processInfo.environment)
    if checked.0 != 0 { fail(checked.1) }
    expect(checked.0 == 0)
}

private let microphoneMockScript = #"""
import json, os, pathlib, re, signal, subprocess, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parent
MOCK=r'''#!/usr/bin/python3
import fcntl,json,os,pathlib,sys,time
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
if name=='flock':
 fd=int(args[-1]); fcntl.flock(fd,fcntl.LOCK_UN if '-u' in args else fcntl.LOCK_EX); sys.exit(0)
if name=='pacat':
 while os.read(0,8192): pass
 sys.exit(0)
p=pathlib.Path(os.environ['PULSE_STATE']); lock=open(str(p)+'.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
s=json.loads(p.read_text()); code=0
if args==['info']: print('Server Name: fixture')
elif args==['get-default-source']: print(s['default'])
elif args[:1]==['set-default-source']:
 if args[1] in s['sources']:s['default']=args[1]
 else:code=1
elif args[:3]==['list','short','sources']:
 for n,x in enumerate(s['sources']):print(n,x,'module',sep='\t')
elif args[:3]==['list','short','modules']:
 for i,v in s['modules'].items():print(i,v['name'],' '.join(v['args']),sep='\t')
elif args[:1]==['load-module']:
 if os.environ.get('FAIL_REMAP') and args[1]=='module-remap-source':code=1
 else:
  i=str(s['next']);s['next']+=1;s['modules'][i]={'name':args[1],'args':args[2:]}
  for a in args[2:]:
   if a.startswith('sink_name='):s['sources'].append(a.split('=',1)[1]+'.monitor')
   if a.startswith('source_name='):s['sources'].append(a.split('=',1)[1])
  print(i)
elif args[:1]==['unload-module']:
 v=s['modules'].pop(args[1],None)
 if v:
  for a in v['args']:
   if a.startswith('sink_name='):s['sources'].remove(a.split('=',1)[1]+'.monitor')
   if a.startswith('source_name='):s['sources'].remove(a.split('=',1)[1])
  if s['default'] not in s['sources']:s['default']=s['sources'][0]
 else:code=1
else:print('bad args',args,file=sys.stderr);code=2
p.write_text(json.dumps(s));sys.exit(code)
'''
with tempfile.TemporaryDirectory(prefix='circe-mic-mock-') as td:
 w=pathlib.Path(td);(w/'bin').mkdir(); state=w/'pulse.json';state.write_text(json.dumps({'default':'hardwareMic','sources':['hardwareMic','otherMic'],'modules':{},'next':1}))
 for n in ['pactl','pacat','flock']:
  p=w/'bin'/n;p.write_text(MOCK);p.chmod(0o700)
 env=dict(os.environ,HOME=str(w),PATH=str(w/'bin')+':/usr/bin:/bin',PULSE_STATE=str(state))
 script=(ROOT/'mic-command-runtime.sh').read_text()
 connections=[]
 def launch(extra=None):
  p=subprocess.Popen(['/bin/bash','-c',script],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(env,**(extra or {})),start_new_session=True)
  connections.append(p)
  line=p.stderr.readline().decode().strip()
  while line and not line.startswith('CIRCE_MIC_'):line=p.stderr.readline().decode().strip()
  assert line.startswith('CIRCE_MIC_READY '),line
  return p,json.loads(line.split(' ',1)[1])
 def snap():return json.loads(state.read_text())
 def stop(p):
  p.stdin.close();p.wait(timeout=10);err=p.stderr.read().decode();assert p.returncode==0,(p.returncode,err)
 try:
  a,ar=launch();b,br=launch();assert ar['source']!=br['source'];assert snap()['default']==br['source']
  stop(a);assert b.poll() is None;assert br['source'] in snap()['sources'];assert snap()['default']==br['source']
  print('PASS: A close preserves B unique source and default')
  stop(b);assert snap()['default']=='hardwareMic';assert not snap()['modules'];print('PASS: final close restores original default and removes owned modules')
  a,ar=launch();b,br=launch();stop(b);assert a.poll() is None;assert snap()['default']==ar['source'];stop(a)
  assert snap()['default']=='hardwareMic' and not snap()['modules'];print('PASS: reverse close order restores the live prior owner, then baseline')
  a,ar=launch();b,br=launch();os.kill(ar['pid'],signal.SIGKILL);a.stdin.close();a.wait(timeout=10)
  deadline=time.time()+8
  while ar['source'] in snap()['sources'] and time.time()<deadline:time.sleep(.1)
  assert ar['source'] not in snap()['sources'];assert b.poll() is None;assert snap()['default']==br['source'];stop(b)
  assert not snap()['modules'];assert snap()['default']=='hardwareMic';print('PASS: kill -9 A sweeps only A; B continues and restores baseline')
  a,ar=launch();subprocess.run([str(w/'bin'/'pactl'),'set-default-source','otherMic'],env=env,check=True);stop(a);assert snap()['default']=='otherMic';print('PASS: cleanup preserves a newer user source choice')
  p=subprocess.Popen(['/bin/bash','-c',script],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(env,FAIL_REMAP='1'),start_new_session=True);connections.append(p);p.stdin.close();p.wait(timeout=10);err=p.stderr.read().decode();assert p.returncode==69 and 'CIRCE_MIC_ERROR source_create' in err and 'CIRCE_MIC_READY' not in err;assert not snap()['modules'];print('PASS: remap failure returns stable error, no READY, no modules')
 finally:
  for process in connections:
   try:os.killpg(process.pid,signal.SIGTERM)
   except ProcessLookupError:pass
   try:process.wait(timeout=2)
   except subprocess.TimeoutExpired:
    try:os.killpg(process.pid,signal.SIGKILL)
    except ProcessLookupError:pass
"""#

private let microphonePrivacyScript = #"""
import AppKit
import SwiftUI
import Foundation

MICROPHONE_ENTRY struct MicUIBehaviorChecks {
    @MainActor static func main() throws {
        let computer = SavedComputer(name: "VM", connection: .ssh(destination: "test@vm", port: nil))
        precondition(!computer.microphoneEnabled)
        precondition(!ComputerDraft().microphoneEnabled)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(computer)) as! [String: Any]
        json.removeValue(forKey: "microphoneConsentVersion")
        json.removeValue(forKey: "microphoneEnabled")
        let absent = try JSONDecoder().decode(SavedComputer.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(!absent.microphoneEnabled, "Missing microphone preference migrates off")
        json["microphoneEnabled"] = true
        let automaticOldTrue = try JSONDecoder().decode(SavedComputer.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(!automaticOldTrue.microphoneEnabled, "An old auto-on true is not consent")
        var optedIn = computer; optedIn.microphoneEnabled = true
        let roundTrip = try JSONDecoder().decode(SavedComputer.self, from: JSONEncoder().encode(optedIn))
        precondition(roundTrip.microphoneEnabled, "New explicit opt-in is remembered")
        let edited = try ComputerDraft(computer: roundTrip).computer()
        precondition(edited.microphoneEnabled)

        let session = RemoteSession(name: "VM", address: "test@vm")
        session.microphoneAvailable = true; session.phase = .streaming
        var requests: [Bool] = []
        session.onMicrophone = { requests.append($0) }
        precondition(!session.isSendingMicrophone && session.microphoneStatus == "Microphone off")
        session.setMicrophone(true)
        precondition(session.microphoneEnabled && !session.isSendingMicrophone && session.microphoneStatus == "Starting microphone…")
        session.microphoneProblem = "Denied"
        precondition(!session.isSendingMicrophone && session.microphoneStatus == "Microphone unavailable")
        session.setMicrophone(true)
        precondition(session.microphoneProblem == nil && requests == [true, true], "Retry is an explicit repeated on request")
        session.microphoneActive = true
        precondition(session.isSendingMicrophone && session.microphoneStatus == "Sending microphone")
        session.phase = .reconnecting(1)
        precondition(!session.isSendingMicrophone && !session.microphoneActive)
        session.phase = .streaming
        precondition(!session.isSendingMicrophone, "Reconnect needs fresh activity acknowledgement")
        session.setMicrophone(false)
        precondition(!session.microphoneActive && !session.isSendingMicrophone && requests.last == false)
        print("Microphone UI/privacy checks passed: default/migration/consent, remembered opt-in, truthful status, retry and stop.")
    }
}
"""#
