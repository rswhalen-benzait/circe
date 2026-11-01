#!/usr/bin/env python3
"""Synthetic AppKit -> actual VNCDisplayView/KeySyms -> actual RFB sendKey body.
No Accessibility prompt, global event injection, VM connection or repository build writes.
Use --view-source to compare an unapplied patch; --allow-failures prints baseline traces.
The transport sink records complete RFB bytes, not an emulated keyboard state machine.
A test-only enabled-state override exercises AppKit delivery during capture handoff.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
parser.add_argument('--view-source', type=Path)
parser.add_argument('--capture-source', type=Path)
parser.add_argument('--allow-failures', action='store_true')
args = parser.parse_args()
repo = args.repo.resolve()
view = args.view_source or repo / 'Sources/CirceVNC/VNCDisplayView.swift'
writer = (repo / 'Sources/CirceVNC/RFBClient.swift').read_text()
body = re.search(r'    func sendKey\(_ keysym: UInt32, down: Bool\) \{\n(.*?)\n    \}', writer, re.S)
if not body:
    raise SystemExit('Update the harness for the changed RFBClient.sendKey signature.')

stubs = r'''
import AppKit
public enum CommandKeyMapping { case control, `super` }
final class RFBFramebuffer { let surface = NSObject() }
struct RFBCursor { let rgba: Data; let width: Int; let height: Int; let hotX: Int; let hotY: Int }
func be32(_ value: UInt32) -> Data {
    Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
          UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
}
final class RecordingStream {
    var bytes = Data()
    func write(_ data: Data) { bytes.append(data) }
    func take() -> [String] {
        precondition(bytes.count % 8 == 0)
        defer { bytes.removeAll() }
        return stride(from: 0, to: bytes.count, by: 8).map { i in
            precondition(bytes[i] == 4 && bytes[i+2] == 0 && bytes[i+3] == 0)
            let sym = bytes[(i+4)..<(i+8)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return String(format: "%@:%04x", bytes[i+1] == 1 ? "D" : "U", sym)
        }
    }
}
final class RFBClient {
    let stream = RecordingStream()
    func sendPointer(x: Int, y: Int, buttons: UInt8) {}
    func sendKey(_ keysym: UInt32, down: Bool) {
WRITER_BODY
    }
}
'''.replace('WRITER_BODY', body.group(1))

main = r'''
import AppKit
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
var failures = 0
func event(_ type: NSEvent.EventType, _ code: UInt16, _ flags: UInt = 0,
           _ chars: String = "", repeat isRepeat: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .init(rawValue: flags),
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                    context: nil, characters: chars, charactersIgnoringModifiers: chars,
                    isARepeat: isRepeat, keyCode: code)!
}
let cmd: UInt = NSEvent.ModifierFlags.command.rawValue
let shift: UInt = NSEvent.ModifierFlags.shift.rawValue
let ctrl: UInt = NSEvent.ModifierFlags.control.rawValue
let left: UInt = 0x08, right: UInt = 0x10
func fixture() -> (VNCDisplayView, RFBClient) {
    let v = VNCDisplayView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
    v.capturesSystemShortcuts = false
    v.commandMapping = .super
    let c = RFBClient(); v.client = c
    return (v, c)
}
func check(_ label: String, _ c: RFBClient, _ expected: [String]) {
    let actual = c.stream.take()
    print("\(actual == expected ? "PASS" : "FAIL") \(label): \(actual.joined(separator: " "))")
    if actual != expected { failures += 1; print("  wanted: \(expected.joined(separator: " "))") }
}
for delay in [0.0, 0.03] {
    for (code, chars, sym) in [(UInt16(0x24), "\r", "ff0d"), (0x12, "1", "0031"),
                               (0x31, " ", "0020"), (0x0d, "w", "0077"),
                               (0x7b, "", "ff51"), (0x7e, "", "ff52"),
                               (0x7c, "", "ff53"), (0x7d, "", "ff54")] {
        let (v,c) = fixture()
        v.flagsChanged(with: event(.flagsChanged, 0x37, cmd|left))
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        v.keyDown(with: event(.keyDown, code, cmd|left, chars))
        v.keyUp(with: event(.keyUp, code, cmd|left, chars))
        v.flagsChanged(with: event(.flagsChanged, 0x37))
        check("normal \(sym), delay=\(delay)", c, ["D:ffeb", "D:\(sym)", "U:\(sym)", "U:ffeb"])
    }
}
do {
    let (v,c)=fixture()
    v.installCaptureForTest()
    v.keyDown(with:event(.keyDown,0x24,cmd|left,"\r"))
    v.keyUp(with:event(.keyUp,0x24,cmd|left,"\r"))
    v.flagsChanged(with:event(.flagsChanged,0x37))
    check("AppKit event queued before capture enabled",c,["D:ffeb","D:ff0d","U:ff0d","U:ffeb"])
}
do {
    let (v,c)=fixture()
    for _ in 0..<2 { v.flagsChanged(with:event(.flagsChanged,0x37,cmd)) }
    v.keyDown(with:event(.keyDown,0x12,cmd,"1"))
    v.keyUp(with:event(.keyUp,0x12,cmd,"1"))
    v.flagsChanged(with:event(.flagsChanged,0x37))
    check("aggregate-only flags are idempotent",c,["D:ffeb","D:0031","U:0031","U:ffeb"])
}
do {
    let (v,c)=fixture()
    v.keyDown(with: event(.keyDown,0x24,cmd|left,"\r"))
    v.keyUp(with: event(.keyUp,0x24,cmd|left,"\r"))
    v.flagsChanged(with: event(.flagsChanged,0x37))
    check("held Command on focus/capture entry (no initial flagsChanged)",c,["D:ffeb","D:ff0d","U:ff0d","U:ffeb"])
}
do {
    let (v,c)=fixture()
    for _ in 0..<2 { v.flagsChanged(with:event(.flagsChanged,0x37,cmd|left)) }
    v.keyDown(with:event(.keyDown,0x12,cmd|left,"1"))
    v.keyUp(with:event(.keyUp,0x12,cmd|left,"1"))
    v.flagsChanged(with:event(.flagsChanged,0x37))
    check("duplicate modifier snapshot",c,["D:ffeb","D:0031","U:0031","U:ffeb"])
}
do {
    let (v,c)=fixture()
    v.flagsChanged(with:event(.flagsChanged,0x37,cmd|left))
    v.keyDown(with:event(.keyDown,0x00,0,"a")) // missed Command release repaired by next key
    v.keyUp(with:event(.keyUp,0x00,0,"a"))
    check("missing modifier-up repaired",c,["D:ffeb","U:ffeb","D:0061","U:0061"])
}
do {
    let (v,c)=fixture()
    v.flagsChanged(with:event(.flagsChanged,0x37,cmd|left))
    v.releaseInput()
    v.keyDown(with:event(.keyDown,0x24,cmd|left,"\r"))
    v.keyUp(with:event(.keyUp,0x24,cmd|left,"\r"))
    v.flagsChanged(with:event(.flagsChanged,0x37))
    check("release then reacquire with Command held",c,["D:ffeb","U:ffeb","D:ffeb","D:ff0d","U:ff0d","U:ffeb"])
}
do {
    let (v,c)=fixture()
    v.flagsChanged(with:event(.flagsChanged,0x37,cmd|left))
    v.flagsChanged(with:event(.flagsChanged,0x36,cmd|left|right))
    v.flagsChanged(with:event(.flagsChanged,0x37,cmd|right))
    v.keyDown(with:event(.keyDown,0x24,cmd|right,"\r"))
    v.keyUp(with:event(.keyUp,0x24,cmd|right,"\r"))
    v.flagsChanged(with:event(.flagsChanged,0x36))
    check("left/right Command overlap",c,["D:ffeb","D:ffec","U:ffeb","D:ff0d","U:ff0d","U:ffec"])
}
do {
    let (v,c)=fixture(); v.commandMapping = .control
    v.flagsChanged(with:event(.flagsChanged,0x37,cmd|left))
    v.flagsChanged(with:event(.flagsChanged,0x3e,cmd|left|ctrl|0x2000))
    v.flagsChanged(with:event(.flagsChanged,0x37,ctrl|0x2000))
    v.flagsChanged(with:event(.flagsChanged,0x3e))
    check("Control_R alias owners",c,["D:ffe4","U:ffe4"])
}
do {
    let (v,c)=fixture()
    v.keyDown(with:event(.keyDown,0x24,cmd|left,"\r"))
    v.keyDown(with:event(.keyDown,0x24,cmd|left,"\r")) // a distinct press after omitted up
    v.keyUp(with:event(.keyUp,0x24,cmd|left,"\r"))
    v.flagsChanged(with:event(.flagsChanged,0x37))
    check("fresh press recovers omitted key-up",c,["D:ffeb","D:ff0d","U:ff0d","D:ff0d","U:ff0d","U:ffeb"])
}
do {
    let (v,c)=fixture()
    v.flagsChanged(with:event(.flagsChanged,0x37,cmd|left))
    v.keyDown(with:event(.keyDown,0x7b,cmd|left,""))
    v.keyDown(with:event(.keyDown,0x7b,cmd|left,"",repeat:true))
    v.keyUp(with:event(.keyUp,0x7b,cmd|left,""))
    v.flagsChanged(with:event(.flagsChanged,0x37))
    check("real repeat remains a held key",c,["D:ffeb","D:ff51","D:ff51","U:ff51","U:ffeb"])
}
do {
    let (v,c)=fixture()
    v.keyDown(with:event(.keyDown,0x0d,cmd|left|shift|0x02,"W"))
    v.keyUp(with:event(.keyUp,0x0d,cmd|left|shift|0x02,"W"))
    v.flagsChanged(with:event(.flagsChanged,0x37))
    check("Shift+Super uses uppercase keysym",c,["D:ffe1","D:ffeb","D:0057","U:0057","U:ffe1","U:ffeb"])
}
do {
    let (v,c)=fixture(); v.isApple=true
    v.keyDown(with:event(.keyDown,0x0d,cmd|right,"w"))
    v.keyUp(with:event(.keyUp,0x0d,cmd|right,"w"))
    v.flagsChanged(with:event(.flagsChanged,0x36))
    check("Apple Meta mapping unchanged",c,["D:ffe8","D:0077","U:0077","U:ffe8"])
}
do {
    let (v,c)=fixture()
    v.flagsChanged(with:event(.flagsChanged,0x37,cmd|left))
    let replacement=RFBClient(); v.client=replacement
    check("old client released on replacement",c,["D:ffeb","U:ffeb"])
    v.keyDown(with:event(.keyDown,0x12,cmd|left,"1"))
    v.keyUp(with:event(.keyUp,0x12,cmd|left,"1"))
    v.flagsChanged(with:event(.flagsChanged,0x37))
    check("new connection gets held modifier",replacement,["D:ffeb","D:0031","U:0031","U:ffeb"])
}
do {
    let (v,c)=fixture()
    let w=NSWindow(contentRect:NSRect(x:0,y:0,width:160,height:100),styleMask:.borderless,backing:.buffered,defer:false)
    w.contentView=v; w.makeFirstResponder(v)
    v.flagsChanged(with:event(.flagsChanged,0x37,cmd|left))
    _=v.performKeyEquivalent(with:event(.keyDown,0x24,cmd|left,"\r"))
    _=v.performKeyEquivalent(with:event(.keyDown,0x24,cmd|left,"\r")) // no AppKit keyUps
    v.flagsChanged(with:event(.flagsChanged,0x37))
    check("AppKit key equivalents without keyUp",c,["D:ffeb","D:ff0d","U:ff0d","D:ff0d","U:ff0d","U:ffeb"])
    v.keyUp(with:event(.keyUp,0x24,0,"\r")) // late AppKit up is harmless
    check("real key-up after balanced equivalent is not duplicated",c,[])
    w.contentView=nil
}
print("\(failures) failed scenario(s)")
exit(failures == 0 || CommandLine.arguments.contains("--allow-failures") ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix='circe-keyboard-') as tmp:
    work = Path(tmp)
    (work / 'Stubs.swift').write_text(stubs)
    (work / 'main.swift').write_text(main)
    # Force only the capture enabled-state dependency, never install a global event tap.
    capture = (args.capture_source or repo / 'Sources/CirceClient/KeyboardCapture.swift').read_text()
    capture, count = re.subn(r'public var isRunning: Bool \{[^\n]*\}',
                            'public var isRunning: Bool { true }', capture, count=1)
    assert count == 1, 'Update the test enabled-state override for KeyboardCapture.'
    (work / 'KeyboardCapture.swift').write_text(capture)
    # Same-file extension can access the view's private capture dependency for one fixture.
    view_text = view.read_text() + '\nextension VNCDisplayView {\n' + \
        '    func installCaptureForTest() { keyboardCapture = KeyboardCapture { _ in } }\n}\n'
    (work / 'VNCDisplayView.swift').write_text(view_text)
    cache = work / 'module-cache'
    common = ['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(cache)]
    subprocess.run(common + ['-emit-library', '-emit-module', '-module-name', 'CirceClient',
        str(work / 'KeyboardCapture.swift'), '-o', str(work / 'libCirceClient.dylib'),
        '-emit-module-path', str(work / 'CirceClient.swiftmodule')], check=True)
    subprocess.run(common + ['-I', str(work), '-L', str(work), '-lCirceClient',
        str(work / 'VNCDisplayView.swift'), str(repo / 'Sources/CirceVNC/KeySyms.swift'), str(work / 'Stubs.swift'),
        str(work / 'main.swift'), '-o', str(work / 'check')], check=True)
    env = dict(os.environ, DYLD_LIBRARY_PATH=str(work))
    result = subprocess.run([str(work / 'check')] + (['--allow-failures'] if args.allow_failures else []), env=env)
    raise SystemExit(result.returncode)
