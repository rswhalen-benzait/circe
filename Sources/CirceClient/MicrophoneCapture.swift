import AVFoundation
import Foundation

/// Converts an input device's PCM to Circe's wire format without accessing microphone hardware.
/// Each instance owns its resampler state and may also be used with synthetic buffers in tests.
public final class MicrophonePCMConverter: @unchecked Sendable {
    private let inputFormat: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter
    private let lock = NSLock()

    public init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: MicrophoneCapture.sampleRate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: output) else {
            throw MicrophoneCapture.Failure.engine("unsupported input format")
        }
        self.inputFormat = inputFormat
        self.output = output
        self.converter = converter
        converter.primeMethod = .none
    }

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        try lock.withLock {
            guard buffer.format.isEqual(inputFormat) else { throw MicrophoneCapture.Failure.engine("the input format changed") }
            guard buffer.frameLength > 0 else { return Data() }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * output.sampleRate / inputFormat.sampleRate)) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
                throw MicrophoneCapture.Failure.engine("couldn’t allocate an audio buffer")
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true; inputStatus.pointee = .haveData; return buffer
            }
            if let error { throw MicrophoneCapture.Failure.engine(error.localizedDescription) }
            guard status != .error else { throw MicrophoneCapture.Failure.engine("audio conversion failed") }
            guard out.frameLength > 0, let samples = out.int16ChannelData else { return Data() }
            return Data(bytes: samples[0], count: Int(out.frameLength) * 2)
        }
    }
}

/// This Mac's microphone as 48 kHz mono signed 16-bit PCM, delivered in ~20 ms chunks.
/// Engine changes are handled off AVAudioEngine's notification queue; stopped/replaced taps
/// cannot restart capture or publish a later running state.
public final class MicrophoneCapture: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible, Sendable {
        case denied, noInput, engine(String)
        public var description: String {
            switch self {
            case .denied: return "Circe isn’t allowed to use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
            case .noInput: return "This Mac has no microphone input available."
            case .engine(let message): return "The microphone couldn’t start: \(message)"
            }
        }
    }
    public enum State: Sendable { case recovering, running, failed(Failure) }

    public static let sampleRate = 48_000.0
    private let engine = AVAudioEngine()
    private let control = DispatchQueue(label: "circe.microphone.capture")
    private let controlKey = DispatchSpecificKey<Bool>()
    private let gate = NSLock()
    private let onData: @Sendable (Data) -> Void
    private let onState: @Sendable (State) -> Void
    private var observer: NSObjectProtocol?
    // Engine/control state: accessed only on control.
    private var wanted = false
    private var tapInstalled = false
    private var inputFormat: AVAudioFormat?
    private var restart: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    private var recovering = false
    private var restartAttempts = 0
    private var recoveryFailure: Failure = .engine("the input device stopped responding. Choose a microphone, then try again.")
    // Tap callbacks share only these small values, protected by gate.
    private var generation: UInt64 = 0
    private var accepting = false
    private var reportedRunning = false
    private var lastFrame = ProcessInfo.processInfo.systemUptime

    public convenience init(onData: @escaping @Sendable (Data) -> Void) {
        self.init(onData: onData, onState: { _ in })
    }
    public init(onData: @escaping @Sendable (Data) -> Void, onState: @escaping @Sendable (State) -> Void) {
        self.onData = onData; self.onState = onState
        control.setSpecific(key: controlKey, value: true)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // Apple's handler runs on an internal queue; tearing the engine down there can deadlock.
            guard let self else { return }
            // Retain until the control work completes, so the last reference cannot release
            // the engine from Apple's notification callback either.
            self.control.async { self.configurationChanged() }
        }
    }

    /// Asks macOS for microphone access if it hasn't been decided yet.
    public static func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default: completion(false)
        }
    }

    public func start() throws {
        try onControl {
            guard !wanted else { return }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Failure.denied }
            wanted = true; recovering = false; restartAttempts = 0
            do { try startEngine(); armWatchdog() }
            catch { wanted = false; stopEngine(); throw error }
        }
    }

    public func stop() {
        onControl {
            wanted = false; recovering = false
            restart?.cancel(); restart = nil
            watchdog?.setEventHandler {}; watchdog?.cancel(); watchdog = nil
            stopEngine()
        }
    }

    private func onControl<T>(_ action: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: controlKey) == true { return try action() }
        return try control.sync(execute: action)
    }

    private func startEngine() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Failure.denied }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        let converter = try MicrophonePCMConverter(inputFormat: format)
        let token = gate.withLock { () -> UInt64 in
            generation &+= 1; accepting = true; reportedRunning = false
            lastFrame = ProcessInfo.processInfo.systemUptime
            return generation
        }
        inputFormat = format
        let chunk = max(1, AVAudioFrameCount(format.sampleRate / 50))
        input.installTap(onBus: 0, bufferSize: chunk, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                let data = try converter.convert(buffer)
                guard !data.isEmpty else { return }
                let accepted: (Bool, Bool) = self.gate.withLock {
                    guard self.accepting, self.generation == token else { return (false, false) }
                    self.lastFrame = ProcessInfo.processInfo.systemUptime
                    let first = !self.reportedRunning; self.reportedRunning = true
                    return (true, first)
                }
                guard accepted.0 else { return }
                self.onData(data)
                if accepted.1 {
                    self.control.async { [weak self] in
                        guard let self, self.wanted, self.isCurrent(token) else { return }
                        self.restartAttempts = 0
                        self.onState(.running)
                    }
                }
            } catch {
                self.control.async { [weak self] in
                    guard let self, self.wanted, self.isCurrent(token) else { return }
                    self.beginRecovery()
                }
            }
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() }
        catch { stopEngine(); throw Failure.engine(error.localizedDescription) }
    }

    private func stopEngine() {
        gate.withLock { accepting = false; generation &+= 1; reportedRunning = false }
        let hadEngine = tapInstalled || engine.isRunning
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if hadEngine { engine.stop(); engine.reset() }
        inputFormat = nil
    }

    private func isCurrent(_ token: UInt64) -> Bool { gate.withLock { accepting && generation == token } }

    private func configurationChanged() {
        guard wanted else { return }
        let current = engine.inputNode.outputFormat(forBus: 0)
        // A delayed notification from our previous restart must not stop the healthy new engine.
        if engine.isRunning, inputFormat?.isEqual(current) == true { return }
        if !recovering, watchdog == nil { restartAttempts = 0 } // a newly available device after exhausted retries
        beginRecovery()
    }

    private func beginRecovery() {
        guard wanted, !recovering else { return }
        recovering = true
        recoveryFailure = .engine("the input device stopped responding. Choose a microphone, then try again.")
        stopEngine()
        onState(.recovering)
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard wanted else { return }
        let delays: [TimeInterval] = [0.2, 0.5, 1, 2, 4]
        guard restartAttempts < delays.count else {
            recovering = false
            watchdog?.setEventHandler {}; watchdog?.cancel(); watchdog = nil
            onState(.failed(recoveryFailure))
            return
        }
        let delay = delays[restartAttempts]; restartAttempts += 1
        let token = gate.withLock { generation }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wanted, self.gate.withLock({ self.generation == token }) else { return }
            self.restart = nil
            do {
                try self.startEngine()
                self.recovering = false
                self.armWatchdog()
            } catch {
                self.recoveryFailure = (error as? Failure) ?? .engine(error.localizedDescription)
                self.stopEngine()
                self.scheduleRestart()
            }
        }
        restart?.cancel(); restart = work
        control.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func armWatchdog() {
        watchdog?.setEventHandler {}; watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.wanted, !self.recovering else { return }
            let idle = self.gate.withLock { ProcessInfo.processInfo.systemUptime - self.lastFrame }
            if !self.engine.isRunning || idle > 2 { self.beginRecovery() }
        }
        watchdog = timer; timer.resume()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        stop()
    }
}
