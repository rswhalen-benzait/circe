#!/usr/bin/env python3
"""Run the Linux installer against local command fixtures; never sudo or contact a VM."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'scripts/linux/setup-circe-host.sh'
MOCK = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['FIXTURE_LOG'], 'a') as f: f.write(json.dumps([name]+args)+'\n')
if name == 'uname': print('Linux')
elif name == 'getent': print(f"fixture:x:{os.environ['FIXTURE_UID']}:20:Fixture:{os.environ['FIXTURE_HOME']}:/bin/bash")
elif name == 'sudo':
    while args[0] in ('-n','--'): args.pop(0)
    os.execvp(args[0], args)
elif name == 'runuser': os.execvp(args[3], args[3:])
elif name in ('apt-get','dnf'):
    assert sys.stdin.buffer.read() == b'', 'Package command must not receive script stdin'
elif name == 'apt-cache': sys.exit(1 if os.environ.get('FIXTURE_NO_TOOLS') else 0)
elif name == 'systemctl':
    if 'is-active' in args or 'is-enabled' in args: sys.exit(1 if os.environ.get('FIXTURE_DOWN') else 0)
elif name == 'loginctl':
    if args[0]=='show-user': print('yes')
elif name == 'ss':
    conf=pathlib.Path(os.environ['FIXTURE_HOME'])/'.config/circe/host.conf'
    display=1
    if conf.exists():
        for line in conf.read_text().splitlines():
            if line.startswith('DISPLAY_NUMBER='): display=int(line.split('=')[1])
    port=5900+display
    host='0.0.0.0' if os.environ.get('FIXTURE_PUBLIC') else '127.0.0.1'
    print(f'LISTEN 0 5 {host}:{port} 0.0.0.0:*')
elif name == 'pactl':
    if args[:3]==['list','short','sources']:
        if not os.environ.get('FIXTURE_NO_AUDIO'): print('1 circe.monitor module-null-sink.c s16le 2ch 48000Hz RUNNING')
    elif args[:3]==['list','short','sinks']: print('1 circe module-null-sink.c s16le 2ch 48000Hz RUNNING')
    elif args[0]=='get-default-sink': print('circe')
    elif args[0]=='load-module': print('42')
elif name == 'tigervncpasswd': sys.stdout.buffer.write(hashlib.sha256(sys.stdin.buffer.read()).digest()[:8])
elif name in ('Xtigervnc','xfce4-session'): os.execl('/bin/sleep','sleep','60')
elif name == 'dbus-run-session': os.execvp(args[1] if args[0]=='--' else args[0],args[1:] if args[0]=='--' else args)
elif name == 'hostname': print('vm.example.net')
elif name == 'curl':
    if not os.environ.get('FIXTURE_GCP'): sys.exit(22)
    print('projects/123/zones/us-central1-a' if 'instance/zone' in args[-1] else 'circe-project' if 'project/project-id' in args[-1] else 'linux-workstation')
'''

with tempfile.TemporaryDirectory(prefix='circe-linux-setup.') as directory:
    temp = Path(directory)
    home = temp / 'Linux account home'
    home.mkdir()
    runtime = temp / 'runtime'
    runtime.mkdir()
    (runtime / 'pulse').mkdir()
    bin_dir = temp / 'bin'
    bin_dir.mkdir()
    log = temp / 'calls.jsonl'
    release = temp / 'os-release'
    release.write_text('ID=ubuntu\nID_LIKE=debian\nPRETTY_NAME="Ubuntu fixture"\n')
    script = temp / 'setup.sh'
    script.write_text(SOURCE.read_text().replace('/etc/os-release', str(release)).replace('RUNTIME="/run/user/$TARGET_UID"', f'RUNTIME="{runtime}"'))
    for name in ['uname', 'getent', 'sudo', 'runuser', 'apt-get', 'apt-cache', 'dnf', 'systemctl', 'loginctl', 'ss', 'pactl', 'parec', 'Xtigervnc', 'tigervncpasswd', 'dbus-run-session', 'xfce4-session', 'xdpyinfo', 'xauth', 'xset', 'curl', 'hostname']:
        command = bin_dir / name
        command.write_text(MOCK)
        command.chmod(0o755)
    environment = {**os.environ, 'PATH': f'{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin', 'FIXTURE_LOG': str(log), 'FIXTURE_HOME': str(home), 'FIXTURE_UID': str(os.getuid() or 1001), 'HOME': str(home), 'XDG_RUNTIME_DIR': str(runtime)}

    def run(*args, extra=None, success=True):
        result = subprocess.run(['/bin/bash', str(script), '--user', 'fixture', *args], env={**environment, **(extra or {})}, text=True, capture_output=True, timeout=15)
        if success and result.returncode:
            raise AssertionError(f'Installer failed ({result.returncode}): {result.stderr}')
        if not success: assert result.returncode != 0
        return result

    result = run()
    assert 'New VNC password' not in result.stdout, 'Non-interactive setup must not put a password in progress output'
    report = json.loads(result.stdout.split('CIRCE_SETUP_RESULT ', 1)[1])
    assert report['display'] == 1 and len(report['password']) == 8 and report['audio'] is True
    assert 'Destination: fixture@vm.example.net' in result.stdout
    password = home / '.vnc/passwd'
    original = password.read_bytes()
    assert len(original) == 8 and password.stat().st_mode & 0o777 == 0o600
    assert 'Wants=pulseaudio.socket' in (home / '.config/systemd/user/circe-audio.service').read_text()
    result = run()
    assert 'Keeping the existing VNC password' in result.stdout and 'New VNC password' not in result.stdout
    assert json.loads(result.stdout.split('CIRCE_SETUP_RESULT ', 1)[1])['password'] is None
    assert password.read_bytes() == original
    run('--reset-password')
    assert password.read_bytes() != original
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert any(call[0] == 'apt-get' and 'install' in call and 'tigervnc-tools' in call for call in calls)
    piped = subprocess.run(['/bin/bash', '-s', '--', '--user', 'fixture'], input=script.read_text(), env=environment, text=True, capture_output=True, timeout=15)
    assert piped.returncode == 0, piped.stderr
    assert 'CIRCE_SETUP_RESULT' in piped.stdout
    run(extra={'FIXTURE_NO_TOOLS': '1'})
    print('Install / rerun / explicit password reset / piped stdin passed; password permissions and optional TigerVNC tools verified.')

    helpers = home / '.local/libexec/circe'
    assert (helpers / 'video').read_text() == (ROOT / 'scripts/linux/circe-video.sh').read_text()
    assert (helpers / 'video').stat().st_mode & 0o777 == 0o700
    for helper in helpers.iterdir():
        subprocess.run(['/bin/bash', '-n', str(helper)], check=True)
        subprocess.run(['shellcheck', str(helper)], check=True)
    desktop = subprocess.Popen(['/bin/bash', str(helpers / 'start-desktop')], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
    try:
        deadline = time.time() + 4
        while time.time() < deadline:
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            if any(call[0] == 'xfce4-session' for call in calls): break
            time.sleep(0.05)
        else: raise AssertionError('Desktop did not start')
        invocation = next(call for call in calls if call[0] == 'Xtigervnc')
        assert '-localhost=1' in invocation and 'yes' not in invocation
        for flag, value in [('-interface', '127.0.0.1'), ('-SecurityTypes', 'VncAuth'), ('-rfbport', '5901'), ('-nolisten', 'tcp')]:
            assert invocation[invocation.index(flag) + 1] == value
        assert invocation[invocation.index('-PasswordFile') + 1] == str(password)
    finally:
        desktop.terminate()
        try: desktop.wait(timeout=4)
        except subprocess.TimeoutExpired: os.killpg(desktop.pid, signal.SIGKILL); desktop.wait()
    assert not (runtime / 'circe-Xauthority').exists()
    print('Generated desktop starts XFCE with loopback-only VNC, private X authority, and no X11 TCP listener; teardown cleans up.')

    def fingerprints():
        return {str(p): hashlib.sha256(p.read_bytes()).digest() for p in home.rglob('*') if p.is_file()}
    before = fingerprints()
    count = len(log.read_text().splitlines())
    run('--check')
    assert fingerprints() == before
    check_calls = [json.loads(line)[0] for line in log.read_text().splitlines()[count:]]
    assert not set(check_calls) & {'sudo', 'apt-get', 'dnf', 'curl'}
    assert 'UNSAFE VNC listener' in run('--check', extra={'FIXTURE_PUBLIC': '1'}, success=False).stdout
    run('--check', extra={'FIXTURE_DOWN': '1'}, success=False)
    run('--check', extra={'FIXTURE_NO_AUDIO': '1'}, success=False)
    print('Read-only check passed; public VNC, failed services, and missing monitor correctly fail.')

    pipewire = bin_dir / 'pipewire-pulse'
    pipewire.write_text(MOCK); pipewire.chmod(0o755)
    result = run('--display', '2', extra={'FIXTURE_GCP': '1'})
    assert all(value in result.stdout for value in ['Connection: Google Cloud', 'linux-workstation', 'us-central1-a', 'circe-project', 'VNC display: 2'])
    assert 'Wants=pipewire-pulse.socket' in (home / '.config/systemd/user/circe-audio.service').read_text()
    release.write_text('ID=rocky\nID_LIKE="rhel centos fedora"\n')
    run()
    assert any(json.loads(line)[0] == 'dnf' and 'xdpyinfo' in json.loads(line) for line in log.read_text().splitlines())
    run('--display', '0', success=False)
    run('--display', '100', success=False)
    run('--geometry', '10x10', success=False)
    run('--unknown', success=False)
    print('PipeWire preservation, GCP instructions, alternate display, RHEL package path, and invalid input checks passed.')
print('Linux setup fixtures passed (no real packages, services, cloud resources, or network connections).')
