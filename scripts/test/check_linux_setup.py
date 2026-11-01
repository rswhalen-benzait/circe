#!/usr/bin/env python3
"""Run the Linux installer against local command fixtures; never sudo or contact a VM."""
import hashlib
import json
import shlex
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
    # FIXTURE_SUDO_PASSWORD set = sudo needs that password; -S reads exactly one line from stdin.
    want = os.environ.get('FIXTURE_SUDO_PASSWORD')
    flags = []
    while args and args[0].startswith('-'):
        flag = args.pop(0)
        if flag == '--': break
        if flag == '-p': args.pop(0); continue
        flags.append(flag)
    if os.environ.get('FIXTURE_SUDO_NO_SHELL') and args[:1] == ['/bin/sh']:
        if '-S' in flags: os.read(0, 4096)
        sys.stderr.write("Sorry, user fixture is not allowed to execute '/bin/sh -c exec \"$@\" </dev/null circe-root' as root on vm.\n"); sys.exit(1)
    if '-S' in flags:
        line = b''
        while not line.endswith(b'\n'):
            byte = os.read(0, 1)
            if not byte: break
            line += byte
        if want is None or line.rstrip(b'\n').decode() != want:
            sys.stderr.write('Sorry, try again.\nsudo: 1 incorrect password attempt\n'); sys.exit(1)
    elif want is not None and not (args and args[0] in os.environ.get('FIXTURE_SUDO_NOPASSWD', '').split(',')):
        sys.stderr.write('sudo: a password is required\n'); sys.exit(1)
    if '-v' in flags or not args: sys.exit(0)
    os.execvp(args[0], args)
elif name == 'runuser': os.execvp(args[3], args[3:])
elif name == 'apt-get' and any(a.startswith('Dir::State::Lists=') for a in args):
    # Without administrator access: user-owned lists; simulate prints what's missing; download writes .debs.
    plain = [a for i, a in enumerate(args) if not a.startswith('-') and (i == 0 or args[i - 1] != '-o')]
    if 'update' in plain: pass
    elif '-s' in args and os.environ.get('FIXTURE_APT_MISSING'): print('E: Unable to locate package jwm'); sys.exit(100)
    elif '-s' in args and os.environ.get('FIXTURE_APT_BROKEN'): print('E: Unable to correct problems, you have held broken packages.'); sys.exit(100)
    elif '-s' in args and os.environ.get('FIXTURE_APT_LIBC'): print('Inst libc6 [2.39-0ubuntu8.3] (2.39-0ubuntu8.4 Ubuntu:24.04/noble-updates [amd64])'); print('Inst jwm (2.4.3-1 fixture [amd64])')
    elif '-s' in args: [print(f'Inst {p} (1.0 fixture [amd64])') for p in plain if p not in ('install',)]
    elif 'download' in plain:
        # Exact versions from the simulated plan (name=version), as a real resolver would pin them.
        assert all('=' in p for p in plain if p != 'download'), plain
        [pathlib.Path(f"{p.split('=')[0]}_{p.split('=')[1]}_amd64.deb").write_text(p.split('=')[0]) for p in plain if p != 'download']
elif name == 'dpkg' and args[:1] == ['-x']:
    root = pathlib.Path(args[2]); deb = pathlib.Path(args[1]).read_text()
    (root / 'usr/bin').mkdir(parents=True, exist_ok=True)
    for tool in {'tigervnc-standalone-server': ['Xtigervnc'], 'jwm': ['jwm'], 'xfce4-terminal': ['xfce4-terminal'], 'thunar': ['thunar']}.get(deb, []):
        (root / 'usr/bin' / tool).write_text('#!/bin/sh\ncase \"$1\" in --version|--help|-help) exit 0;; esac\nexec sleep 60\n'); (root / 'usr/bin' / tool).chmod(0o755)
    (root / 'usr/lib/x86_64-linux-gnu').mkdir(parents=True, exist_ok=True)
elif name == 'loginctl' and [a for a in args if a != '--no-ask-password'][:1] == ['enable-linger'] and os.environ.get('FIXTURE_NO_SELF_LINGER'):
    sys.exit(1)
elif name in ('apt-get','dnf','pacman'):
    if name == 'pacman' and args[:1] == ['-Qq']: sys.exit(1)
    assert sys.stdin.buffer.read() == b'', 'Package command must not receive script stdin'
elif name == 'apt-cache': sys.exit(1 if os.environ.get('FIXTURE_NO_TOOLS') else 0)
elif name == 'systemctl':
    if 'is-active' in args or 'is-enabled' in args: sys.exit(1 if os.environ.get('FIXTURE_DOWN') else 0)
elif name == 'loginctl':
    flag = pathlib.Path(os.environ['FIXTURE_LINGER_FLAG'])
    args = [a for a in args if a != '--no-ask-password']
    if args[0]=='show-user': print('yes' if flag.exists() else 'no')
    elif args[0]=='enable-linger': flag.touch()
elif name == 'ss':
    conf=pathlib.Path(os.environ['FIXTURE_HOME'])/'.config/circe/host.conf'
    display=1
    if conf.exists():
        for line in conf.read_text().splitlines():
            if line.startswith('DISPLAY_NUMBER='): display=int(line.split('=')[1])
    port=5900+display
    host='0.0.0.0' if os.environ.get('FIXTURE_PUBLIC') else '127.0.0.1'
    print(f'LISTEN 0 5 {host}:{port} 0.0.0.0:*' + (' users:(("Xtigervnc",pid=7,fd=5))' if '-ltnp' in args else ''))
    if '-ltnp' in args and os.environ.get('FIXTURE_WAYVNC'):
        print('LISTEN 0 16 127.0.0.1:5900 0.0.0.0:* users:(("wayvnc",pid=1093,fd=10))')
        print('LISTEN 0 5 0.0.0.0:5905 0.0.0.0:* users:(("x11vnc",pid=2,fd=3))')
        print('LISTEN 0 4096 0.0.0.0:47989 0.0.0.0:* users:(("sunshine",pid=3,fd=4))')
elif name == 'ps':
    assert args[:2] == ['-u', 'fixture'], 'Probe must only list the target user\'s processes'
    if 'pid=,ppid=,args=' in args:
        # An open Chrome Remote Desktop session (its Xvfb is the host's child), a test runner's Xvfb, an RDP Xorg.
        if os.environ.get('FIXTURE_OPEN_SESSION'):
            print('100 1 /usr/bin/python3 /opt/google/chrome-remote-desktop/chrome-remote-desktop --start\n'
                  '200 1 xvfb-run -a pytest\n201 200 Xvfb :99 -screen 0 1x1x24\n'
                  f'300 1 /usr/lib/xorg/Xorg :10 -auth {os.environ["FIXTURE_HOME"]}/.Xauthority -config xrdp/xorg.conf\n'
                  + ('' if os.environ.get('FIXTURE_OPEN_SESSION') == 'rdp' else f'101 100 Xvfb :20 -auth {os.environ["FIXTURE_HOME"]}/.Xauthority -nolisten tcp\n'))
        else: print('1 0 bash')
    else: print('bash\nHyprland\nwayvnc\nsunshine' if os.environ.get('FIXTURE_WAYVNC') else 'bash')
elif name == 'pgrep': sys.exit(0 if os.environ.get('FIXTURE_WAYVNC') and '-x' not in args else 1)
elif name == 'timeout' and not any('/dev/tcp' in a for a in args):
    if args[0].startswith('--kill-after='): args.pop(0)
    args.pop(0); os.execvp(args[0], args)
elif name == 'timeout':
    # timeout 2 bash -c '…/dev/tcp/$0/$1…' HOST PORT: answer like a VNC server on the listed ports.
    if args[-1] in os.environ.get('FIXTURE_RFB_PORTS', '').split(','): sys.stdout.write('RFB 003.008\n')
    else: sys.exit(1)
elif name == 'id': print('fixture wheel' if os.environ.get('FIXTURE_ADMIN') else 'fixture')
elif name == 'pactl':
    if args[:3]==['list','short','sources']:
        if not os.environ.get('FIXTURE_NO_AUDIO'): print('1 circe.monitor module-null-sink.c s16le 2ch 48000Hz RUNNING')
    elif args[:3]==['list','short','sinks']: print('1 circe module-null-sink.c s16le 2ch 48000Hz RUNNING')
    elif args[0]=='get-default-sink': print('circe')
    elif args[0]=='load-module': print('42')
elif name == 'tigervncpasswd': sys.stdout.buffer.write(hashlib.sha256(sys.stdin.buffer.read()).digest()[:8])
elif name in ('Xtigervnc','xfce4-session','X0tigervnc'):
    if name == 'Xtigervnc' and os.environ.get('FIXTURE_HEALTH_FAIL') and int(os.environ.get('DISPLAY', ':0')[1:]) >= 100: sys.exit(1)
    os.execl('/bin/sleep','sleep','60')
elif name == 'xdpyinfo' and os.environ.get('FIXTURE_HEALTH_FAIL') and int(os.environ.get('DISPLAY', ':0')[1:]) >= 100: sys.exit(1)
elif name == 'dbus-run-session': os.execvp(args[1] if args[0]=='--' else args[0],args[1:] if args[0]=='--' else args)
elif name == 'hostname': print('vm.example.net')
elif name == 'flock': sys.exit(1 if os.environ.get('FIXTURE_LOCKED') else 0)
elif name == 'mv':
    if '-Tf' in args:
        plain=[a for a in args if a not in ('-Tf','--')]; os.replace(plain[0],plain[1])
    else: os.execv('/bin/mv',['mv',*args])
elif name == 'df':
    if os.environ.get('FIXTURE_DISK_FULL'): print('Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 10000000 9800000 200000 98% /')
    else: os.execv('/bin/df', ['df', *args])
elif name == 'curl':
    if not os.environ.get('FIXTURE_GCP'): sys.exit(22)
    print('projects/123/zones/us-central1-a' if 'instance/zone' in args[-1] else 'circe-project' if 'project/project-id' in args[-1] else 'linux-workstation')
'''

def check_arch_signer_policy():
    """Exercise the actual helpers with machine-status/key-policy fixtures, never a real keyring."""
    text = SOURCE.read_text()
    helpers = text[text.index('arch_verification_possible() {'):text.index('self_linger_allowed() {')]
    fingerprint = 'A' * 40
    primary = 'B' * 40
    valid = (f'[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG {fingerprint[-16:]} Packager\n'
             f'[GNUPG:] VALIDSIG {fingerprint} 2026-01-01 1767225600 0 4 0 22 8 00 {primary}\n'
             '[GNUPG:] TRUST_FULLY 0 pgp\n')
    listing = (f'pub:f:255:22:{primary[-16:]}:1700000000:0::f:::scSC:\n'
               f'fpr:::::::::{primary}:\n'
               f'sub:f:255:22:{fingerprint[-16:]}:1700000000:0:::::s:\n'
               f'fpr:::::::::{fingerprint}:\n')
    with tempfile.TemporaryDirectory(prefix='circe-arch-policy.') as directory:
        work = Path(directory)
        original = work / 'system-keyring'; original.mkdir()
        (original / 'pubring.gpg').write_text('PUBLIC-ONLY')
        (original / 'trustdb.gpg').write_text('TRUST-AND-DISABLED-POLICY')
        # Copying the entire homedir would include these unwanted files.
        (original / 'gpg.conf').write_text('trust-model always\nauto-key-retrieve\n')
        (original / 'private-keys-v1.d').mkdir()
        (original / 'private-keys-v1.d/key').write_text('DO-NOT-COPY')
        bin_dir = work / 'bin'; bin_dir.mkdir()
        log = work / 'gpg-calls.jsonl'
        gpg = bin_dir / 'gpg'
        gpg.write_text(r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args=sys.argv[1:]
with open(os.environ['ARCH_LOG'], 'a') as f:f.write(json.dumps(args)+'\n')
assert '--no-options' in args and '--no-autostart' in args
assert '--no-auto-key-retrieve' in args and '--no-auto-key-import' in args
assert args[args.index('--trust-model')+1]=='pgp'
home=pathlib.Path(args[args.index('--homedir')+1]); original=pathlib.Path(os.environ['ARCH_ORIGINAL'])
assert home != original and home.stat().st_mode & 0o777 == 0o700
assert sorted(p.name for p in home.iterdir())==['pubring.gpg','trustdb.gpg']
assert (home/'pubring.gpg').read_text()=='PUBLIC-ONLY'
assert (home/'trustdb.gpg').read_text().startswith('TRUST-AND-DISABLED-POLICY')
assert (home/'pubring.gpg').stat().st_mode & 0o777 == 0o600
assert (home/'trustdb.gpg').stat().st_mode & 0o777 == 0o600
(home/'trustdb.gpg').write_text('TRUST-AND-DISABLED-POLICY (private refresh)')
if '--list-keys' in args:
 assert args[-1]==os.environ['ARCH_PRIMARY']
 assert args.count('--fingerprint')==2
 print(os.environ['ARCH_LISTING'],end='')
else:
 assert args[args.index('--status-fd')+1]=='1' and '--verify' in args
 assert pathlib.Path(args[-1]).read_text()=='PAYLOAD'
 assert pathlib.Path(args[-2]).read_text()=='DETACHED-SIGNATURE'
 print(os.environ['ARCH_STATUS'],end='')
 sys.exit(int(os.environ.get('ARCH_EXIT','0')))
''')
        gpg.chmod(0o755)
        package = work / 'package.pkg.tar.zst'; package.write_text('PAYLOAD')
        Path(str(package) + '.sig').write_text('DETACHED-SIGNATURE')
        cache = work / 'cache'; cache.mkdir()
        script = work / 'check.sh'
        prefix = 'set -euo pipefail\numask 077\nfail() { printf \'CIRCE_SETUP_ERROR {"code":"%s"}\\n\' "$1"; exit 1; }\n'
        local_helpers = helpers.replace('/etc/pacman.d/gnupg', str(original))
        script.write_text(prefix + local_helpers + '\nprepare_arch_keyring\nverify_arch_package "$1"\necho VERIFIED\n')
        environment = {**os.environ, 'PATH': f'{bin_dir}:/usr/bin:/bin', 'PACKAGE_CACHE': str(cache),
                       'ARCH_LOG': str(log), 'ARCH_ORIGINAL': str(original), 'ARCH_PRIMARY': primary,
                       'ARCH_STATUS': valid, 'ARCH_LISTING': listing}
        def verify(label, status=valid, keys=listing, exit_code=0, accepted=False):
            result = subprocess.run(['/bin/bash', str(script), str(package)],
                                    env={**environment, 'ARCH_STATUS': status, 'ARCH_LISTING': keys, 'ARCH_EXIT': str(exit_code)},
                                    text=True, capture_output=True, timeout=10)
            assert (result.returncode == 0) == accepted, (label, result.stdout, result.stderr)
            if accepted: assert result.stdout.strip() == 'VERIFIED', (label, result)
            else: assert 'CIRCE_SETUP_ERROR {"code":"package_unverified"}' in result.stdout, (label, result)
            if (original / 'trustdb.gpg').exists():
                assert (original / 'trustdb.gpg').read_text() == 'TRUST-AND-DISABLED-POLICY', 'Never refresh the system trustdb'
            return result
        verify('fully trusted', accepted=True)
        verify('ultimately trusted', valid.replace('TRUST_FULLY', 'TRUST_ULTIMATE'), listing.replace(':f:', ':u:'), accepted=True)
        for bad in ['REVKEYSIG', 'EXPKEYSIG', 'EXPSIG', 'BADSIG', 'ERRSIG']:
            verify(bad, valid.replace('GOODSIG', bad))
        # Real Arch keyrings report other, expired/revoked keys in the trust path; the signer itself is judged by
        # GOODSIG vs EXPKEYSIG/REVKEYSIG and its listed validity.
        for other in ['KEYEXPIRED', 'KEYREVOKED']:
            verify('unrelated ' + other, valid + f'[GNUPG:] {other} 1642399435\n', accepted=True)
        for bad in ['SIGEXPIRED', 'NO_PUBKEY', 'FAILURE', 'ERROR', 'NODATA']:
            verify(bad, valid + f'[GNUPG:] {bad} 1\n')
        for trust in ['TRUST_NEVER', 'TRUST_UNDEFINED', 'TRUST_MARGINAL']:
            verify(trust, valid.replace('TRUST_FULLY', trust))
        verify('missing VALIDSIG', '\n'.join(line for line in valid.splitlines() if 'VALIDSIG' not in line))
        verify('unpaired/multiple signatures', valid + valid)
        verify('nonzero verification despite statuses', exit_code=2)
        verify('disabled primary', keys=listing.replace('scSC:', 'scSCD:'))
        verify('expired signing subkey', keys=listing.replace('sub:f:', 'sub:e:'))
        verify('revoked primary', keys=listing.replace('pub:f:', 'pub:r:'))
        verify('unknown validity', keys=listing.replace('pub:f:', 'pub:-:'))
        verify('missing exact signing subkey', keys=listing.replace(f'fpr:::::::::{fingerprint}:', f'fpr:::::::::{"C"*40}:'))
        # A system trustdb is mandatory, including for the read-only capability test.
        (original / 'trustdb.gpg').unlink()
        verify('missing trust database')
        capability = subprocess.run(['/bin/bash', '-c', prefix + local_helpers + '\narch_verification_possible'],
                                    env=environment, text=True, capture_output=True, timeout=10)
        assert capability.returncode != 0, 'Probe must not offer Arch without readable trust policy'
        print('Arch verification: private public/trust policy, full/ultimate trust, rejected revoked/expired/disabled/untrusted/malformed signers, missing prerequisites; no global writes.')

check_arch_signer_policy()


def check_audio_failures_and_migration():
    source = SOURCE.read_text()
    status = source[source.index('report_status() {'):source.index('# ---- Installing without administrator access')]
    choose = source[source.index('select_audio_backend() {'):source.index('\nif $USERSPACE; then', source.index('select_audio_backend() {'))]
    activate = source[source.index('activate_audio() {'):source.index('\nactivate_audio\n', source.index('activate_audio() {'))]
    # Exercise the actual functions. All service and sound operations are controlled fixture functions;
    # no user manager, PulseAudio daemon, sudo or network connection is touched.
    with tempfile.TemporaryDirectory(prefix='circe-audio-policy.') as directory:
        temp = Path(directory)
        home = temp / 'account home'
        units = home / '.config/systemd/user'
        config = home / '.config/circe'
        units.mkdir(parents=True); config.mkdir(parents=True)
        (config / 'vncpasswd').write_bytes(b'password')
        script = temp / 'check.sh'
        prelude = r'''set -euo pipefail
TARGET_HOME="$FIXTURE_AUDIO_HOME"
PREFIX="$TARGET_HOME/.local/share/circe/root"
PREFIX_ENV="$TARGET_HOME/.config/circe/prefix.env"
UNITS="$TARGET_HOME/.config/systemd/user"
CONFIG="$TARGET_HOME/.config/circe"
LIBEXEC="$TARGET_HOME/.local/libexec/circe"
TARGET_USER=fixture
PASSWORD_FILE="$CONFIG/vncpasswd"
DISPLAY_NUMBER=1
VNC_PORT=5901
USERSPACE=${FIXTURE_PRIVATE_MODE:-false}
NEED_ROOT=false
PERSISTENT=true
system_command() { [[ "$1" == "${FIXTURE_SYSTEM_SOUND:-none}" ]]; }
as_user() { "$@"; }
systemctl() {
    printf '%s\n' "$*" >> "$FIXTURE_AUDIO_LOG"
    [[ "${FIXTURE_AUDIO_FAILURE:-}" != "$*" ]] || return 1
    if [[ "$*" == '--user is-active --quiet circe-audio.service' && "${FIXTURE_AUDIO_DOWN:-false}" == true ]]; then return 3; fi
    return 0
}
loginctl() { printf 'yes\n'; }
ss() { printf 'LISTEN 0 10 127.0.0.1:5901 0.0.0.0:*\n'; }
user_tool() { printf '1 circe.monitor module-null-sink.c\n'; }
'''
        script.write_text(prelude + choose + '\n' + activate + '\n' + status + r'''
printf 'BACKEND=%s PRIVATE_COUNT=%d\n' "$BACKEND_UNIT" "${#PRIVATE_PULSE[@]}"
activate_audio
if report_status false; then printf 'CORE_READY=true AUDIO_READY=%s\n' "$AUDIO_READY"; else printf 'CORE_READY=false\n'; exit 1; fi
''')
        def invoke(**extra):
            log = temp / 'calls'
            log.write_text('')
            result = subprocess.run(['/bin/bash', str(script)], env={**os.environ, 'FIXTURE_AUDIO_HOME': str(home), 'FIXTURE_AUDIO_LOG': str(log), **extra}, text=True, capture_output=True, timeout=5)
            assert result.returncode == 0, result.stderr + result.stdout
            return result.stdout, log.read_text().splitlines()

        # Both a new private setup and repair without --without-admin select the same real backend.
        output, _ = invoke(FIXTURE_PRIVATE_MODE='true')
        assert 'BACKEND=circe-pulse.service PRIVATE_COUNT=1' in output
        (config / 'prefix.env').touch()
        (units / 'circe-pulse.service').write_text('[Service]\nExecStart=private\n')
        output, calls = invoke()
        assert 'BACKEND=circe-pulse.service PRIVATE_COUNT=1' in output
        assert '--user enable --now pulseaudio.socket' not in calls
        assert '--user stop circe-pulse.service' not in calls
        for server in ('pulseaudio', 'pipewire-pulse'):
            output, calls = invoke(FIXTURE_SYSTEM_SOUND=server)
            enable = f'--user enable --now {server}.socket'
            assert f'BACKEND={server}.socket PRIVATE_COUNT=0' in output
            assert calls.index('--user stop circe-pulse.service') < calls.index(enable)
            assert calls.index('--user disable circe-pulse.service') < calls.index(enable)
            assert not any(c.startswith(('--user stop ', '--user disable ')) and not c.endswith('circe-pulse.service') for c in calls)

        # Every failed backend/loop unit operation is optional, and the final audio flag stays false
        # even if an old server still exposes a monitor during the failing migration.
        for failure in (
            '--user stop circe-pulse.service', '--user disable circe-pulse.service',
            '--user enable --now pipewire-pulse.socket', '--user enable circe-audio.service',
            '--user restart circe-audio.service',
        ):
            output, _ = invoke(FIXTURE_SYSTEM_SOUND='pipewire-pulse', FIXTURE_AUDIO_FAILURE=failure)
            assert 'CORE_READY=true AUDIO_READY=false' in output, (failure, output)
        output, _ = invoke(FIXTURE_AUDIO_FAILURE='--user restart circe-pulse.service')
        assert 'CORE_READY=true AUDIO_READY=false' in output
        output, _ = invoke(FIXTURE_AUDIO_DOWN='true')
        assert 'CORE_READY=true AUDIO_READY=false' in output

        # PATH order cannot mistake a private daemon for a system server after a later host install.
        helper = source[source.index('system_command() {'):source.index('\nselect_audio_backend() {')]
        private_bin = home / '.local/share/circe/root/usr/bin'; private_bin.mkdir(parents=True)
        system_bin = temp / 'system-bin'; system_bin.mkdir()
        for bindir in (private_bin, system_bin):
            tool = bindir / 'circe-fixture-sound'
            tool.write_text('#!/bin/sh\nexit 0\n'); tool.chmod(0o700)
        path_script = temp / 'path.sh'
        path_script.write_text('TARGET_HOME="$1"; PREFIX="$TARGET_HOME/.local/share/circe/root"\n' + helper + '\nsystem_command circe-fixture-sound\n')
        result = subprocess.run(['/bin/bash', str(path_script), str(home)], env={**os.environ, 'PATH': f'{private_bin}:{system_bin}:/usr/bin:/bin'}, capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, result.stderr
        (system_bin / 'circe-fixture-sound').unlink()
        result = subprocess.run(['/bin/bash', str(path_script), str(home)], env={**os.environ, 'PATH': f'{private_bin}:{system_bin}:/usr/bin:/bin'}, capture_output=True, text=True, timeout=5)
        assert result.returncode != 0, 'A private-only executable is not a system sound server'
    print('Audio failures remain optional; private repair, backend migration and system/private PATH discrimination passed.')


check_audio_failures_and_migration()

def check_arch_real_signers():
    # Actual GnuPG integration, using only synthetic OpenPGP packets and OpenSSL test signing. No GPG
    # secret key or agent is needed; private-key PEMs live only inside this disposable fixture directory.
    import shutil
    import struct
    if not shutil.which('gpg') or not shutil.which('openssl'):
        print('Real GPG signer fixtures skipped (gpg/openssl missing); mandatory status-policy fixtures still run.')
        return
    def command(args, data=None, okay=True):
        r=subprocess.run(args,input=data,capture_output=True,env={**os.environ,'LC_ALL':'C'},timeout=20)
        if okay and r.returncode: raise RuntimeError((args,r.returncode,r.stdout.decode(errors='replace'),r.stderr.decode(errors='replace')))
        return r

    def size(n):
        if n<192:return bytes([n])
        if n<8384:return bytes([((n-192)>>8)+192,(n-192)&255])
        return b'\xff'+struct.pack('>I',n)
    def packet(tag,body):return bytes([0xc0|tag])+size(len(body))+body
    def mpi(n):
        return struct.pack('>H',n.bit_length())+n.to_bytes((n.bit_length()+7)//8,'big')
    def sp(tag,body):return size(1+len(body))+bytes([tag])+body

    def key(work,label,created):
        pem=work/(label+'.pem')
        command(['openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:2048','-out',str(pem)])
        modulus=int(command(['openssl','rsa','-in',str(pem),'-noout','-modulus']).stdout.decode().strip().split('=',1)[1],16)
        body=b'\x04'+struct.pack('>I',created)+b'\x01'+mpi(modulus)+mpi(65537)
        frame=b'\x99'+struct.pack('>H',len(body))+body
        return {'pem':pem,'body':body,'frame':frame,'fpr':hashlib.sha1(frame).digest()}

    def signature(work,key,kind,data,stamp,extra=b''):
        hashed=sp(2,struct.pack('>I',stamp))+sp(33,b'\x04'+key['fpr'])+extra
        header=bytes([4,kind,1,8])+struct.pack('>H',len(hashed))+hashed
        unhashed=sp(16,key['fpr'][-8:])
        payload=data+header+b'\x04\xff'+struct.pack('>I',len(header))
        digest=hashlib.sha256(payload).digest()
        signed=command(['openssl','dgst','-sha256','-sign',str(key['pem'])],payload).stdout
        return header+struct.pack('>H',len(unhashed))+unhashed+digest[:2]+mpi(int.from_bytes(signed,'big'))

    def setup(work,name,expired=False,revoked=False,trust=True,subkey=True,full_trust=False,disabled=False):
        stamp=int(time.time())-3*86400
        primary=key(work,name+'-primary',stamp)
        uid=b'Circe fixture <fixture@example.invalid>'
        uidframe=b'\xb4'+struct.pack('>I',len(uid))+uid
        extra=sp(27,b'\x01' if subkey else b'\x03')
        if expired:extra+=sp(9,struct.pack('>I',86400))
        cert=signature(work,primary,0x13,primary['frame']+uidframe,stamp,extra)
        raw=packet(6,primary['body'])
        if revoked:
            revocation=signature(work,primary,0x20,primary['frame'],stamp+1,sp(29,b'\x00fixture revocation'))
            raw+=packet(2,revocation)
        raw+=packet(13,uid)+packet(2,cert)
        authority=None
        if full_trust:
            authority=key(work,name+'-authority',stamp)
            raw+=packet(2,signature(work,authority,0x13,primary['frame']+uidframe,stamp+1))
        signer=primary
        if subkey:
            signer=key(work,name+'-sub',stamp)
            cross=signature(work,signer,0x19,primary['frame']+signer['frame'],stamp)
            binding=signature(work,primary,0x18,primary['frame']+signer['frame'],stamp,sp(27,b'\x02')+sp(32,cross))
            raw+=packet(14,signer['body'])+packet(2,binding)
        if authority:
            auth_uid=b'Circe authority <authority@example.invalid>'
            auth_uidframe=b'\xb4'+struct.pack('>I',len(auth_uid))+auth_uid
            auth_cert=signature(work,authority,0x13,authority['frame']+auth_uidframe,stamp,sp(27,b'\x03'))
            raw+=packet(6,authority['body'])+packet(13,auth_uid)+packet(2,auth_cert)
        public=work/(name+'.pub');public.write_bytes(raw)
        package=work/(name+'.pkg');package.write_bytes(b'Circe synthetic package bytes\n')
        Path(str(package)+'.sig').write_bytes(packet(2,signature(work,signer,0,package.read_bytes(),stamp+2)))
        home=work/(name+'-gnupg');home.mkdir(mode=0o700,exist_ok=True)
        args=['gpg','--no-options','--homedir',str(home),'--batch','--no-tty','--no-autostart','--no-auto-key-retrieve','--no-auto-key-import','--trust-model','pgp']
        imported=command(args+['--import',str(public)],okay=False)
        assert imported.returncode in (0,2), imported.stderr
        if trust:command(args+['--import-ownertrust'],(authority or primary)['fpr'].hex().encode()+b':6:\n')
        if disabled:
            command(args+['--command-fd','0','--edit-key',primary['fpr'].hex()],b'disable\nsave\n',okay=False)
        result=command(args+['--status-fd','1','--verify',str(package)+'.sig',str(package)],okay=False)
        listing=command(args+['--with-colons','--fixed-list-mode','--fingerprint','--fingerprint','--list-keys',primary['fpr'].hex()],okay=False)
        return package,home,args,result,listing


    source = SOURCE.read_text()
    helpers = source[source.index('arch_verification_possible() {'):source.index('self_linger_allowed() {')]
    with tempfile.TemporaryDirectory(prefix='circe-real-signers.') as directory:
        work=Path(directory)
        cases=[('valid-subkey',{},True,'TRUST_ULTIMATE'),
               ('valid-primary',{'subkey':False},True,'TRUST_ULTIMATE'),
               ('valid-full-trust',{'full_trust':True},True,'TRUST_FULLY'),
               ('expired',{'expired':True},False,'EXPKEYSIG'),
               ('revoked',{'revoked':True},False,'REVKEYSIG'),
               ('untrusted',{'trust':False},False,'TRUST_UNDEFINED'),
               ('disabled',{'disabled':True},False,'TRUST_ULTIMATE')]
        for name,options,accepted,expected_status in cases:
            package,home,args,direct,listing=setup(work,name,**options)
            # Expired/revoked/untrusted signatures remain cryptographically valid (often GPG exit zero).
            assert b'[GNUPG:] VALIDSIG ' in direct.stdout, (name,direct.stderr)
            assert expected_status.encode() in direct.stdout, (name,direct.stdout,direct.stderr)
            if name=='disabled':
                assert any('D' in line.split(':')[11] for line in listing.stdout.decode().splitlines() if line.startswith('pub:')), listing.stdout
            (home/'pubring.gpg').write_bytes(command(args+['--export']).stdout)
            # The production helper copies the same public ring/trustdb format pacman uses, not the source kbx.
            before=(home/'trustdb.gpg').read_bytes()
            cache=home/'cache';cache.mkdir()
            prefix='set -euo pipefail\numask 077\nfail() { printf \'CIRCE_SETUP_ERROR {"code":"%s"}\\n\' "$1"; exit 1; }\n'
            runner=home/'helper.sh'
            runner.write_text(prefix+helpers.replace('/etc/pacman.d/gnupg',str(home))+'\nprepare_arch_keyring\nverify_arch_package "$1"\necho VERIFIED\n')
            result=subprocess.run(['/bin/bash',str(runner),str(package)],env={**os.environ,'PACKAGE_CACHE':str(cache)},text=True,capture_output=True,timeout=20)
            assert (result.returncode==0)==accepted,(name,result.stdout,result.stderr)
            if accepted:assert result.stdout.strip()=='VERIFIED',(name,result)
            else:assert 'CIRCE_SETUP_ERROR {"code":"package_unverified"}' in result.stdout,(name,result)
            assert (home/'trustdb.gpg').read_bytes()==before, 'Verification must not refresh the source system trustdb'
        print('Real GPG integration: valid primary/subkey/full trust accepted; revoked, expired, untrusted and disabled keys rejected; copied trust policy untouched.')

check_arch_real_signers()


def check_runtime_transaction_fixtures():
    """Exercise actual transaction helpers against isolated account files and process/service doubles."""
    import select
    import signal
    import shutil
    source = SOURCE.read_text()
    transaction = source[source.index('acquire_setup_lock() {'):source.index('without_admin_possible() {')]
    mocks = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
name=pathlib.Path(sys.argv[0]).name; args=sys.argv[1:]
if name == 'mv':
    words=[x for x in args if x != '--' and not x.startswith('-')]
    assert len(words)==2, args
    src,dst=words; boundary=os.environ.get('TRANSACTION_BOUNDARY','')
    if boundary=='canonical' and '.link.' in src: sys.exit(42)
    if boundary=='environment' and src.endswith('/prefix.env.new'): sys.exit(43)
    os.replace(src,dst)
elif name == 'systemctl':
    with open(os.environ['TRANSACTION_CALLS'],'a') as f:f.write(json.dumps(args)+'\n')
    if os.environ.get('TRANSACTION_BOUNDARY')=='core-start' and args[:3]==['--user','restart','circe-desktop.service']:sys.exit(44)
elif name == 'flock':
    import fcntl
    try:fcntl.flock(int(args[-1]),fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:sys.exit(1)
'''
    with tempfile.TemporaryDirectory(prefix='circe-transaction-review.') as directory:
        root=Path(directory); commands=root/'bin';commands.mkdir()
        for name in ('mv','systemctl','flock'):
            executable=commands/name;executable.write_text(mocks);executable.chmod(0o755)
        script=root/'transaction.sh'
        script.write_text(r'''#!/bin/bash
set -euo pipefail
TARGET_HOME=$TRANSACTION_HOME
CONFIG="$TARGET_HOME/.config/circe";LIBEXEC="$TARGET_HOME/.local/libexec/circe";UNITS="$TARGET_HOME/.config/systemd/user"
PREFIX="$TARGET_HOME/.local/share/circe/root";PACKAGE_CACHE="$TARGET_HOME/.cache/circe/packages";PREFIX_ENV="$CONFIG/prefix.env"
SETUP_BASE_PATH="$PATH"
as_user() { "$@"; }
fail() { echo "CIRCE_SETUP_ERROR $1"; exit 1; }
''' + transaction + r'''
prepare_private_runtime() {
    [[ "${TRANSACTION_BOUNDARY:-}" != preparation ]] || return 45
    mkdir -p "$CONFIG"; printf '%s' "$PREFIX" > "$CONFIG/candidate-cache"
}
write_prefix_env() {
    [[ "${TRANSACTION_BOUNDARY:-}" != generated-environment ]] || return 46
    printf 'candidate=%s\n' "$PREFIX" > "$PREFIX_ENV"
}
health_check_runtime() {
    grep -qF "$CANDIDATE" "$1"
    [[ "${TRANSACTION_BOUNDARY:-}" != health ]] || return 47
}
setup_begin
if [[ "${TRANSACTION_ACTION:-}" == recovery ]]; then setup_commit; exit 0; fi
CANDIDATE="$TARGET_HOME/.local/share/circe/releases/new"
mkdir -p "$CANDIDATE"; printf CANDIDATE > "$CANDIDATE/runtime"
activate_private_runtime "$CANDIDATE"
printf NEW > "$CONFIG/host.conf"
[[ "${TRANSACTION_BOUNDARY:-}" != host-configuration ]] || exit 48
printf NEW > "$LIBEXEC/start-desktop"
[[ "${TRANSACTION_BOUNDARY:-}" != helper ]] || exit 49
printf NEW > "$UNITS/circe-desktop.service"
[[ "${TRANSACTION_BOUNDARY:-}" != unit ]] || exit 50
touch "$SETUP_TRANSACTION/services-touched"
printf PUBLISHED > "$CONFIG/vncpasswd"
case "${TRANSACTION_ACTION:-}" in
    hup) kill -HUP $$; sleep 1 ;;
    term) kill -TERM $$; sleep 1 ;;
    interrupted) trap - EXIT HUP INT TERM; exit 99 ;;
    failure) exit 51 ;;
esac
clean_user systemctl --user restart circe-desktop.service
setup_commit
''')
        def account(label, legacy=False):
            home=root/label
            config=home/'.config/circe';helpers=home/'.local/libexec/circe';units=home/'.config/systemd/user'
            cache=home/'.cache/circe/packages';old=home/'.local/share/circe/releases/old';prefix=home/'.local/share/circe/root'
            for path in (config,helpers,units,cache,old):path.mkdir(parents=True)
            (old/'runtime').write_text('OLD')
            (config/'prefix.env').write_text('OLD ENVIRONMENT')
            (config/'host.conf').write_text('OLD CONFIGURATION')
            (config/'fonts.conf').write_text('OLD CACHE')
            (config/'vncpasswd').write_text('ORIGINAL')
            (helpers/'start-desktop').write_text('OLD HELPER')
            for unit in ('circe-desktop.service','circe-audio.service','circe-pulse.service'):(units/unit).write_text('OLD UNIT '+unit)
            if legacy:
                prefix.mkdir();(prefix/'runtime').write_text('LIVE LEGACY')
            else:prefix.symlink_to(old)
            return home,old,prefix
        def run(home,boundary='',action='',success=False):
            env={**os.environ,'PATH':f'{commands}:/usr/bin:/bin','TRANSACTION_HOME':str(home),
                 'TRANSACTION_CALLS':str(root/'calls.jsonl'),'TRANSACTION_BOUNDARY':boundary,'TRANSACTION_ACTION':action}
            result=subprocess.run(['/bin/bash',str(script)],env=env,text=True,capture_output=True,timeout=15)
            assert (result.returncode==0)==success,(boundary,action,result.returncode,result.stdout,result.stderr)
            return result
        def restored(home,old,prefix,password='ORIGINAL'):
            config=home/'.config/circe';helpers=home/'.local/libexec/circe';units=home/'.config/systemd/user'
            assert prefix.resolve()==old.resolve() and (old/'runtime').read_text()=='OLD'
            assert (config/'prefix.env').read_text()=='OLD ENVIRONMENT'
            assert (config/'host.conf').read_text()=='OLD CONFIGURATION'
            assert (config/'fonts.conf').read_text()=='OLD CACHE'
            assert (config/'vncpasswd').read_text()==password
            assert (helpers/'start-desktop').read_text()=='OLD HELPER'
            assert (units/'circe-desktop.service').read_text()=='OLD UNIT circe-desktop.service'
            assert not (home/'.cache/circe/packages/active-transaction').exists()
        for boundary in ('preparation','generated-environment','health','canonical','environment','host-configuration','helper','unit','core-start'):
            home,old,prefix=account('failure-'+boundary)
            print('Transaction boundary:',boundary)
            run(home,boundary=boundary)
            restored(home,old,prefix,password='PUBLISHED' if boundary=='core-start' else 'ORIGINAL')
        for action,status in (('hup',129),('term',143)):
            home,old,prefix=account('signal-'+action)
            result=run(home,action=action)
            assert result.returncode==status,result
            restored(home,old,prefix,password='PUBLISHED')
        home,old,prefix=account('recover-uncommitted')
        run(home,action='interrupted')
        assert (home/'.cache/circe/packages/active-transaction').exists()
        run(home,action='recovery',success=True)
        restored(home,old,prefix,password='PUBLISHED')
        home,old,prefix=account('successful-repair')
        run(home,success=True)
        assert (old/'runtime').read_text()=='OLD','A successful commit must retain the previous immutable runtime'
        assert prefix.resolve()==(home/'.local/share/circe/releases/new').resolve()
        assert (home/'.config/circe/prefix.env').read_text().startswith('candidate=')
        home,old,prefix=account('legacy-live',legacy=True)
        run(home,success=True)
        assert prefix.is_dir() and not prefix.is_symlink() and (prefix/'runtime').read_text()=='LIVE LEGACY'
        # All mutation modes enter the same helper before package/password/config changes. Real kernel
        # flock in the fixture preserves ownership across helper fork/exec and exercises the FIFO lease.
        lock_script=root/'lock.sh'
        prefix=r'''#!/bin/bash
set -euo pipefail
TARGET_HOME=$TRANSACTION_HOME;TARGET_UID=$(id -u)
CONFIG="$TARGET_HOME/.config/circe";LIBEXEC="$TARGET_HOME/.local/libexec/circe";UNITS="$TARGET_HOME/.config/systemd/user"
PREFIX="$TARGET_HOME/.local/share/circe/root";PACKAGE_CACHE="$TARGET_HOME/.cache/circe/packages";PREFIX_ENV="$CONFIG/prefix.env"
SETUP_BASE_PATH="$PATH"
as_user() { "$@"; }
fail() { echo "CIRCE_SETUP_ERROR $1"; exit 1; }
'''
        lock_script.write_text(prefix+transaction+r'''
acquire_setup_lock
printf 'ACQUIRED %s\n' "$TRANSACTION_MODE"
if [[ "$TRANSACTION_MODE" == holder ]]; then IFS= read -r ignored || true; fi
if [[ "$TRANSACTION_MODE" == worker ]]; then
    printf '%s' "$SETUP_LOCK_DIR" > "$TARGET_HOME/worker-lock-directory"
    as_user bash -c 'echo WORKING; sleep 2; touch "$1/worker-finished"' _ "$TARGET_HOME" &
    wait $!
fi
''')
        lock_home=root/'lock account';lock_home.mkdir()
        lock_environment={**os.environ,'PATH':f'{commands}:/usr/bin:/bin','TRANSACTION_HOME':str(lock_home),
                          'TRANSACTION_CALLS':str(root/'calls.jsonl'),'TRANSACTION_MODE':'holder'}
        holder=subprocess.Popen(['/bin/bash',str(lock_script)],env=lock_environment,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                text=True,start_new_session=True)
        try:
            readable,_,_=select.select([holder.stdout],[],[],10)
            assert readable,'Account lock holder never became ready'
            assert holder.stdout.readline().strip()=='ACQUIRED holder'
            for mode in ('system','private','repair'):
                blocked=subprocess.run(['/bin/bash',str(lock_script)],env={**lock_environment,'TRANSACTION_MODE':mode},
                                       text=True,capture_output=True,timeout=15)
                assert blocked.returncode!=0 and 'CIRCE_SETUP_ERROR setup_running' in blocked.stdout,(mode,blocked)
            holder.stdin.close();holder.wait(timeout=10)
            assert holder.returncode==0,holder.stderr.read()
            acquired=subprocess.run(['/bin/bash',str(lock_script)],env={**lock_environment,'TRANSACTION_MODE':'repair'},
                                    text=True,capture_output=True,timeout=15)
            assert acquired.returncode==0 and 'ACQUIRED repair' in acquired.stdout,acquired
        finally:
            if holder.poll() is None:
                os.killpg(holder.pid,signal.SIGTERM)
                try:holder.wait(timeout=3)
                except subprocess.TimeoutExpired:os.killpg(holder.pid,signal.SIGKILL);holder.wait()
        worker=subprocess.Popen(['/bin/bash',str(lock_script)],env={**lock_environment,'TRANSACTION_MODE':'worker'},
                                stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
        try:
            assert worker.stdout.readline().strip()=='ACQUIRED worker'
            assert worker.stdout.readline().strip()=='WORKING'
            os.kill(worker.pid,signal.SIGKILL);worker.wait(timeout=5)
            blocked=subprocess.run(['/bin/bash',str(lock_script)],env={**lock_environment,'TRANSACTION_MODE':'repair'},
                                   text=True,capture_output=True,timeout=15)
            assert blocked.returncode!=0 and 'setup_running' in blocked.stdout, 'A mutation worker keeps the lock after its parent dies'
            deadline=time.time()+5
            while not (lock_home/'worker-finished').exists() and time.time()<deadline:time.sleep(.02)
            assert (lock_home/'worker-finished').exists()
            time.sleep(.1)
            acquired=subprocess.run(['/bin/bash',str(lock_script)],env={**lock_environment,'TRANSACTION_MODE':'repair'},
                                    text=True,capture_output=True,timeout=15)
            assert acquired.returncode==0,acquired
        finally:
            if worker.poll() is None:os.killpg(worker.pid,signal.SIGKILL);worker.wait()
            directory=lock_home/'worker-lock-directory'
            if directory.exists():shutil.rmtree(directory.read_text(),ignore_errors=True)
        assert source.index('if $PROBE || $CHECK; then') < source.index('\nacquire_setup_lock\n')
        assert source.index('    report_status; exit $?') < source.index('\nacquire_setup_lock\n')
        assert source.index('\nacquire_setup_lock\n') < source.index('\nUSERSPACE=false\n')
        print('Account lock: system/private/repair contend on one kernel lock; FIFO EOF releases it; probe/check precede acquisition.')
        print('Runtime transactions: prepare/health/promotion/config/helper/unit/core failures, HUP/TERM, unfinished-journal recovery, published password and old/live legacy runtime retention passed.')

check_runtime_transaction_fixtures()

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
    script.write_text(SOURCE.read_text().replace('/etc/os-release', str(release)).replace('/etc/pacman.d/gnupg', str(temp / 'missing-arch-policy')).replace('RUNTIME="/run/user/$TARGET_UID"', f'RUNTIME="{runtime}"'))
    for name in ['uname', 'getent', 'sudo', 'runuser', 'apt-get', 'apt-cache', 'dnf', 'dpkg', 'pacman', 'ps', 'pgrep', 'id', 'timeout', 'systemctl', 'loginctl', 'ss', 'pactl', 'parec', 'Xtigervnc', 'tigervncpasswd', 'dbus-run-session', 'xfce4-session', 'xdpyinfo', 'xauth', 'xset', 'curl', 'hostname', 'flock', 'df', 'mv']:
        command = bin_dir / name
        command.write_text(MOCK)
        command.chmod(0o755)
    linger = temp / 'linger'
    # The computer's own desktops (xsessions); empty unless a test adds one.
    xsessions = temp / 'xsessions'; xsessions.mkdir()
    environment = {**os.environ, 'CIRCE_XSESSIONS': str(xsessions), 'FIXTURE_LINGER_FLAG': str(linger), 'PATH': f'{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin', 'FIXTURE_LOG': str(log), 'FIXTURE_HOME': str(home), 'FIXTURE_UID': str(os.getuid() or 1001), 'HOME': str(home), 'XDG_RUNTIME_DIR': str(runtime)}

    def run(*args, extra=None, success=True, lingering=None):
        # Package installs need root unless the tools are present and lingering is on; most runs test installs.
        if lingering is None: lingering = '--check' in args or '--probe' in args
        if lingering: linger.touch()
        else: linger.unlink(missing_ok=True)
        result = subprocess.run(['/bin/bash', str(script), '--user', 'fixture', *args], env={**environment, **(extra or {})}, text=True, capture_output=True, timeout=15)
        if success and result.returncode:
            raise AssertionError(f'Installer failed ({result.returncode}): {result.stderr}')
        if success is False: assert result.returncode != 0
        return result

    result = run()
    assert 'New VNC password' not in result.stdout, 'Non-interactive setup must not put a password in progress output'
    report = json.loads(result.stdout.split('CIRCE_SETUP_RESULT ', 1)[1])
    assert report['display'] == 1 and len(report['password']) == 8 and report['audio'] is True
    assert 'Destination: fixture@vm.example.net' in result.stdout
    password = home / '.config/circe/vncpasswd'
    original = password.read_bytes()
    assert len(original) == 8 and password.stat().st_mode & 0o777 == 0o600
    assert 'Wants=pulseaudio.socket' in (home / '.config/systemd/user/circe-audio.service').read_text()
    assert json.loads(result.stdout.split('CIRCE_SETUP_SECRET ', 1)[1].splitlines()[0])['password'] == report['password'], 'The new password is reported as soon as it exists'
    assert 'set-default-sink' not in (home / '.local/libexec/circe/start-audio').read_text(), 'Other sessions keep their default output'
    assert 'export PULSE_SINK=circe' in (home / '.local/libexec/circe/start-desktop').read_text()
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

    # Another VNC server's ~/.vnc/passwd is never reused or touched; older Circe installs keep theirs.
    for label, has_circe_conf in (('unrelated', False), ('legacy', True)):
        other = temp / f'{label} home'
        (other / '.vnc').mkdir(parents=True)
        (other / '.vnc/passwd').write_bytes(b'OTHERVNC')
        if has_circe_conf:
            (other / '.config/circe').mkdir(parents=True)
            (other / '.config/circe/host.conf').write_text('DISPLAY_NUMBER=1\nGEOMETRY=1600x1000\n')
        outcome = run(extra={'FIXTURE_HOME': str(other), 'HOME': str(other)})
        reported = json.loads(outcome.stdout.split('CIRCE_SETUP_RESULT ', 1)[1])['password']
        assert (other / '.vnc/passwd').read_bytes() == b'OTHERVNC', 'An existing ~/.vnc/passwd is left alone'
        if has_circe_conf: assert reported is None and not (other / '.config/circe/vncpasswd').exists(), 'Older Circe desktops keep their password'
        else: assert reported and len((other / '.config/circe/vncpasswd').read_bytes()) == 8, 'New installs get their own password'
    print('Circe uses its own VNC password file; an unrelated ~/.vnc/passwd is never reused or changed.')

    helpers = home / '.local/libexec/circe'
    for media in ('video', 'audio'):
        assert (helpers / media).read_text() == (ROOT / f'scripts/linux/circe-{media}.sh').read_text()
        assert (helpers / media).stat().st_mode & 0o777 == 0o700
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

    # The computer's own desktop (what its login screen, RDP or Chrome Remote Desktop shows) wins over Circe's.
    def session_file(name, body): (xsessions / f'{name}.desktop').write_text('[Desktop Entry]\n' + body)
    session_env = temp / 'session-env'
    gnome = bin_dir / 'gnome-session'
    gnome.write_text('#!/bin/bash\nenv > "$FIXTURE_SESSION_ENV"; printf "%s\\n" "$*" >> "$FIXTURE_SESSION_ENV"\n'
                     '[[ -n "$FIXTURE_SESSION_FAIL" ]] && exit 3\nexec sleep 30\n')
    gnome.chmod(0o755)
    session_file('custom', 'Name=Custom\nExec=default\n')                                    # runs ~/.xsession: never picked
    session_file('i3', f'Name=i3\nExec={bin_dir}/xfce4-session\n')                              # no DesktopNames
    session_file('xfce', f'Name=Xfce Session\nExec={bin_dir}/xfce4-session\nDesktopNames=XFCE\n')
    session_file('ubuntu', f'Name=Ubuntu\nExec=env GNOME_SHELL_SESSION_MODE=ubuntu {gnome} --session=ubuntu\nTryExec={gnome}\nDesktopNames=ubuntu;GNOME\n'
                 '[Desktop Action other]\nName=Wrong\nExec=/nonexistent\n')
    session_file('plasma', 'Name=Plasma\nExec=startplasma-x11\nTryExec=/nonexistent/startplasma-x11\n')   # not installed
    session_file('gnome', f'Name=GNOME\nExec={gnome}\nHidden=true\n')                         # hidden
    probe = json.loads(run('--probe').stdout.split('CIRCE_PROBE_RESULT ', 1)[1])
    assert probe['systemDesktop'] == {'id': 'ubuntu', 'name': 'Ubuntu'}, probe['systemDesktop']
    assert "Desktop: Ubuntu (this computer's own)" in run('--check').stdout
    picked = subprocess.run([str(helpers / 'system-session')], env=environment, capture_output=True, text=True)
    assert picked.stdout.split('\x1f') == ['ubuntu', 'Ubuntu', 'ubuntu;GNOME', f'env GNOME_SHELL_SESSION_MODE=ubuntu {gnome} --session=ubuntu\n'], picked.stdout
    (xsessions / 'ubuntu.desktop').unlink()
    picked = subprocess.run([str(helpers / 'system-session')], env=environment, capture_output=True, text=True).stdout.rstrip('\n').split('\x1f')
    assert picked[:3] == ['xfce', 'Xfce Session', 'XFCE'], 'A full desktop before a bare window manager'
    (xsessions / 'xfce.desktop').unlink()
    picked = subprocess.run([str(helpers / 'system-session')], env=environment, capture_output=True, text=True).stdout.rstrip('\n').split('\x1f')
    assert picked == ['i3', 'i3', '', f'{bin_dir}/xfce4-session'], 'A missing DesktopNames keeps the fields in place'
    (xsessions / 'i3.desktop').unlink()
    session_file('ubuntu', f'Name=Ubuntu\nExec=env GNOME_SHELL_SESSION_MODE=ubuntu {gnome} --session=ubuntu\nTryExec={gnome}\nDesktopNames=ubuntu;GNOME\n')
    def start_desktop(extra):
        session_env.unlink(missing_ok=True)
        count = len(log.read_text().splitlines())
        env = {**environment, 'FIXTURE_SESSION_ENV': str(session_env), 'LD_LIBRARY_PATH': '/opt/system-lib', **extra}
        desktop = subprocess.Popen(['/bin/bash', str(helpers / 'start-desktop')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True, text=True)
        return desktop, count
    prefix_env = home / '.config/circe/prefix.env'
    prefix_env.write_text('export CIRCE_PREFIX=/private/prefix\nexport LD_LIBRARY_PATH=/private/prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\n'
                          'export XDG_DATA_DIRS=/private/prefix/share:${XDG_DATA_DIRS:-/usr/share}\nexport PATH="$PATH:/private/prefix/bin"\n')
    desktop, count = start_desktop({'XDG_DATA_DIRS': '/usr/share:/var/lib/snapd/desktop'})
    try:
        deadline = time.time() + 4
        while time.time() < deadline and not (session_env.exists() and '--session=ubuntu' in session_env.read_text()): time.sleep(0.05)
        seen = dict(line.split('=', 1) for line in session_env.read_text().splitlines() if '=' in line and not line.startswith('--'))
        assert seen['XDG_CURRENT_DESKTOP'] == 'ubuntu:GNOME' and seen['DESKTOP_SESSION'] == 'ubuntu' and seen['XDG_SESSION_DESKTOP'] == 'ubuntu'
        assert seen['GNOME_SHELL_SESSION_MODE'] == 'ubuntu' and seen['XDG_SESSION_TYPE'] == 'x11' and seen['PULSE_SINK'] == 'circe' and seen['DISPLAY'] == ':1'
        assert 'CIRCE_PREFIX' not in seen and seen['LD_LIBRARY_PATH'] == '/opt/system-lib', 'The computer\'s desktop never loads Circe\'s private libraries'
        assert seen['XDG_DATA_DIRS'] == '/usr/share:/var/lib/snapd/desktop' and '/private/prefix' not in seen['PATH']
        calls = [json.loads(line) for line in log.read_text().splitlines()[count:]]
        assert not any(call[0] == 'xfce4-session' for call in calls), 'Only one desktop runs'
        assert any(call[0] == 'dbus-run-session' for call in calls), 'Its own D-Bus session, apart from other desktops of the account'
    finally:
        desktop.terminate()
        try: desktop.wait(timeout=4)
        except subprocess.TimeoutExpired: os.killpg(desktop.pid, signal.SIGKILL); desktop.wait()
    # A desktop that can't run inside Xvnc stops right away: Circe's light desktop instead of a blank screen.
    prefix_env.unlink()
    desktop, count = start_desktop({'FIXTURE_SESSION_FAIL': '1'})
    try:
        deadline = time.time() + 6
        while time.time() < deadline and not any(json.loads(line)[0] == 'xfce4-session' for line in log.read_text().splitlines()[count:]): time.sleep(0.05)
        assert any(json.loads(line)[0] == 'xfce4-session' for line in log.read_text().splitlines()[count:]), 'Falls back to the light desktop'
        assert desktop.poll() is None
    finally:
        desktop.terminate()
        try: _, err = desktop.communicate(timeout=4)
        except subprocess.TimeoutExpired: os.killpg(desktop.pid, signal.SIGKILL); _, err = desktop.communicate()
    assert 'stopped right away' in err, err
    count = len(log.read_text().splitlines())
    run()
    installs = [json.loads(line) for line in log.read_text().splitlines()[count:] if 'apt-get' in line and 'install' in line]
    assert installs and not any('xfce4' in call for call in installs) and any('tigervnc-standalone-server' in call for call in installs), \
        'A computer with its own desktop gets only TigerVNC'
    assert 'Restart=always' in (home / '.config/systemd/user/circe-desktop.service').read_text(), 'Signing out starts a fresh desktop'
    # A desktop session that's already open (Chrome Remote Desktop, RDP) is shown as it is: no second desktop.
    (home / '.Xauthority').write_text('cookie')
    sharer = bin_dir / 'X0tigervnc'
    sharer.write_text(MOCK); sharer.chmod(0o755)
    shared_env = runtime / 'circe/desktop.env'
    for which, display, kind in [('crd', '20', 'chrome-remote-desktop'), ('rdp', '10', 'rdp')]:
        desktop, count = start_desktop({'FIXTURE_OPEN_SESSION': which})
        try:
            deadline = time.time() + 4
            while time.time() < deadline and not any(json.loads(line)[0] == 'X0tigervnc' for line in log.read_text().splitlines()[count:]): time.sleep(0.05)
            calls = [json.loads(line) for line in log.read_text().splitlines()[count:]]
            share = next((call for call in calls if call[0] == 'X0tigervnc'), None)
            if share is None:
                desktop.terminate(); _, err = desktop.communicate(timeout=5)
                raise AssertionError(f'The open session was not shown: {err} {calls}')
            for flag, value in [('-display', ':' + display), ('-rfbport', '5901'), ('-interface', '127.0.0.1'), ('-SecurityTypes', 'VncAuth')]:
                assert share[share.index(flag) + 1] == value, share
            assert '-localhost=1' in share and share[share.index('-PasswordFile') + 1] == str(password)
            assert not any(call[0] in ('Xtigervnc', 'xfce4-session', 'dbus-run-session') for call in calls), 'Only the open session is shown'
            settings = dict(line.split('=', 1) for line in shared_env.read_text().splitlines())
            assert settings['CIRCE_SHARED_DISPLAY'] == display and settings['CIRCE_SHARED_KIND'] == kind, settings
            sourced = subprocess.run(['/bin/sh', '-c', '. "$1"; printf %s "$CIRCE_SHARED_XAUTHORITY"', '_', str(shared_env)], capture_output=True, text=True).stdout
            assert sourced == str(home / '.Xauthority'), 'A POSIX shell (the audio command) reads the file back exactly, spaces included'
            assert f'the session already open on display :{display}' in run('--check').stdout
            assert json.loads(run('--probe').stdout.split('CIRCE_PROBE_RESULT ', 1)[1])['circe']['shared'] == kind
        finally:
            desktop.terminate()
            try: desktop.wait(timeout=4)
            except subprocess.TimeoutExpired: os.killpg(desktop.pid, signal.SIGKILL); desktop.wait()
        assert not shared_env.exists(), 'Stopping forgets the shared session'
    # If the session can't be shown, Circe starts a desktop of its own rather than retrying forever.
    sharer.write_text('#!/bin/sh\nexit 1\n')
    desktop, count = start_desktop({'FIXTURE_OPEN_SESSION': 'crd'})
    try:
        deadline = time.time() + 6
        while time.time() < deadline and not any(json.loads(line)[0] == 'Xtigervnc' for line in log.read_text().splitlines()[count:]): time.sleep(0.05)
        assert any(json.loads(line)[0] == 'Xtigervnc' for line in log.read_text().splitlines()[count:]), 'Falls back to its own desktop'
    finally:
        desktop.terminate()
        try: desktop.wait(timeout=4)
        except subprocess.TimeoutExpired: os.killpg(desktop.pid, signal.SIGKILL); desktop.wait()
    sharer.unlink()
    for entry in list(xsessions.iterdir()): entry.unlink()
    print("The computer's own desktop (GNOME…) runs instead of Circe's, with system libraries, its own D-Bus and a light fallback; only TigerVNC is installed.")

    # The light desktop's Applications menu lists the computer's apps.
    apps = temp / 'apps-data'; (apps / 'applications').mkdir(parents=True)
    user_apps = home / '.local/share/applications'; user_apps.mkdir(parents=True, exist_ok=True)
    def app(directory, name, body): (directory / f'{name}.desktop').write_text('[Desktop Entry]\nType=Application\n' + body)
    app(apps / 'applications', 'google-chrome', 'Name=Google Chrome\nExec=/usr/bin/google-chrome-stable %U\nCategories=Network;WebBrowser;\n'
        '[Desktop Action new-window]\nName=New Window\nExec=/usr/bin/google-chrome-stable --new-window\n')
    app(apps / 'applications', 'code', 'Name=Visual Studio Code\nExec=/usr/share/code/code %F\nCategories=TextEditor;Development;IDE;\n')
    app(apps / 'applications', 'htop', 'Name=Htop\nExec=htop\nTerminal=true\nCategories=System;Monitor;\n')
    app(apps / 'applications', 'gnome-panel', 'Name=Displays\nExec=gnome-control-center display\nOnlyShowIn=GNOME;Unity;\nCategories=Settings;\n')
    app(apps / 'applications', 'hidden', 'Name=Hidden\nExec=hidden\nNoDisplay=true\n')
    app(apps / 'applications', 'gone', 'Name=Gone\nExec=gone\nTryExec=/nonexistent/gone\n')
    app(apps / 'applications', 'ampersand', 'Name=Tom & Jerry <2>\nExec=tj --name "a b" %%done\nCategories=Game;\n')
    app(apps / 'applications', 'overridden', 'Name=System copy\nExec=system-copy\n')
    app(user_apps, 'overridden', 'Name=My copy\nExec=my-copy\n')
    menu_env = {**environment, 'XDG_DATA_DIRS': str(apps), 'XDG_CURRENT_DESKTOP': 'XFCE'}
    import xml.etree.ElementTree as ET
    jwm = ET.fromstring(subprocess.run([str(helpers / 'app-menu'), 'jwm'], env=menu_env, capture_output=True, text=True, check=True).stdout)
    menus = {m.get('label'): {p.get('label'): p.text for p in m} for m in jwm}
    assert menus['Internet'] == {'Google Chrome': '/usr/bin/google-chrome-stable'}, menus
    assert menus['Development'] == {'Visual Studio Code': '/usr/share/code/code'}
    assert menus['System']['Htop'] in ('xterm -e htop', 'xfce4-terminal -x htop'), 'Terminal apps open in a terminal'
    assert menus['Games'] == {'Tom & Jerry <2>': 'tj --name "a b" %done'}, 'Labels and commands are escaped; %% is a percent sign'
    assert menus['Other'] == {'My copy': 'my-copy'}, 'The account\'s own entry overrides the system\'s'
    assert 'Settings' not in menus and not any('Hidden' in m or 'Gone' in m for m in menus.values()), 'GNOME-only, hidden and uninstalled apps are left out'
    openbox = ET.fromstring(subprocess.run([str(helpers / 'app-menu'), 'openbox'], env=menu_env, capture_output=True, text=True, check=True).stdout)
    assert openbox.tag == 'openbox_pipe_menu' and {m.get('label') for m in openbox} == set(menus)
    assert openbox.find(".//menu[@label='Internet']/item/action/command").text == '/usr/bin/google-chrome-stable'
    light = (helpers / 'light-session').read_text()
    assert '<Dynamic label="Applications">exec:' in light and 'execute="%s openbox"' in light
    print('The light desktop has an Applications menu of installed apps (snaps, Flatpaks, the account\'s own), refreshed when opened.')

    def fingerprints():
        return {str(p): hashlib.sha256(p.read_bytes()).digest() for p in home.rglob('*') if p.is_file()}
    before = fingerprints()
    count = len(log.read_text().splitlines())
    run('--check')
    assert fingerprints() == before
    check_calls = [json.loads(line)[0] for line in log.read_text().splitlines()[count:]]
    assert not set(check_calls) & {'sudo', 'apt-get', 'dnf', 'curl', 'flock'}
    assert 'UNSAFE VNC listener' in run('--check', extra={'FIXTURE_PUBLIC': '1'}, success=False).stdout
    run('--check', extra={'FIXTURE_DOWN': '1'}, success=False)
    # Sound is optional: a missing monitor is reported, but the desktop itself is healthy.
    assert 'Audio: unavailable' in run('--check', extra={'FIXTURE_NO_AUDIO': '1'}).stdout
    print('Read-only check passed; public VNC and failed services fail; missing sound is reported, not fatal.')

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

    # Circe's remote wrapper (LinuxSetup.run): first stdin line is the sudo password (maybe empty), the rest
    # is the script; the password reaches the script only on descriptor 3, never argv or the environment.
    WRAPPER = 'set +x; f=$(mktemp) && IFS= read -r p && cat > "$f" && { printf \'%s\\n\' "$p" | CIRCE_SUDO_PASSWORD_FD=3 bash "$f" "$@" 3<&0 </dev/null; }; rc=$?; unset p; rm -f "$f"; exit $rc'
    def circe(password, *args, extra=None):
        linger.unlink(missing_ok=True)
        return subprocess.run(['/bin/sh', '-c', WRAPPER, 'circe', '--user', 'fixture', *args], input=password + '\n' + script.read_text(),
                              env={**environment, **(extra or {})}, text=True, capture_output=True, timeout=15)
    secret = 'pa ss"w\\ord$(x)'
    needs = {'FIXTURE_SUDO_PASSWORD': secret}
    release.write_text('ID=ubuntu\nID_LIKE=debian\nPRETTY_NAME="Ubuntu fixture"\n')
    result = circe('', extra=needs)
    assert result.returncode != 0 and 'CIRCE_SETUP_ERROR {"code":"sudo_password_required"}' in result.stdout, result
    result = circe('wrong', extra=needs)
    assert result.returncode != 0 and 'CIRCE_SETUP_ERROR {"code":"sudo_password_incorrect"}' in result.stdout, result
    count = len(log.read_text().splitlines())
    result = circe(secret, extra=needs)
    assert result.returncode == 0 and 'CIRCE_SETUP_RESULT' in result.stdout, result.stderr
    assert secret not in result.stdout + result.stderr + log.read_text(), 'The sudo password must not reach argv or output'
    new_calls = [json.loads(line) for line in log.read_text().splitlines()[count:]]
    assert any(c[0] == 'sudo' and '-S' in c and '-k' in c and 'apt-get' in c for c in new_calls), 'Password sudo must not reuse cached credentials'
    assert all(c[c.index('--') + 1:c.index('--') + 3] == ['/bin/sh', '-c'] for c in new_calls if c[0] == 'sudo' and '-S' in c and '-v' not in c), 'Privileged commands get /dev/null stdin'
    assert circe('', '--probe').returncode == 0, 'An empty password line means passwordless sudo'
    traced = subprocess.run(['/bin/sh', '-c', 'set -x; ' + WRAPPER, 'circe', '--user', 'fixture', '--probe'], input=secret + '\n' + script.read_text(),
                            env={**environment, **needs}, text=True, capture_output=True, timeout=15)
    assert secret not in traced.stdout + traced.stderr, 'Tracing left on by a login shell must not print the password'
    count = len(log.read_text().splitlines())
    result = circe(secret, extra={**needs, 'FIXTURE_SUDO_NO_SHELL': '1'})
    assert result.returncode == 0, result.stderr
    assert any(c[0] == 'sudo' and c[-1] != 'circe-root' and 'apt-get' in c and '/bin/sh' not in c for c in (json.loads(l) for l in log.read_text().splitlines()[count:])), \
        'Command-only sudo policies still work'
    assert secret not in result.stdout + result.stderr
    result = circe(secret, extra={**needs, 'FIXTURE_SUDO_NO_SHELL': '1', 'FIXTURE_SUDO_NOPASSWD': 'apt-get'})
    assert result.returncode == 0, result.stderr  # fake apt-get fails if anything (the password) reaches its stdin
    rootless = run(extra={**needs}, lingering=True)
    assert 'no administrator access needed' in rootless.stdout, 'Restarting/repairing an installed desktop needs no sudo'
    print('Sudo password: required / incorrect are reported as codes; accepted password installs without reaching argv, output, or command stdin.')

    release.write_text('ID=omarchy\nID_LIKE=arch\nPRETTY_NAME="Omarchy"\n')
    count = len(log.read_text().splitlines())
    run()
    arch_calls = [json.loads(line) for line in log.read_text().splitlines()[count:] if json.loads(line)[0] == 'pacman']
    assert any(c[1:4] == ['-S', '--needed', '--noconfirm'] and 'tigervnc' in c and 'xorg-xdpyinfo' in c for c in arch_calls), arch_calls
    assert not any(any(a.startswith('-S') and 'y' in a for a in c[1:]) for c in arch_calls), 'Never refresh pacman (partial upgrade)'
    release.write_text('ID=gentoo\nPRETTY_NAME="Gentoo"\n')
    assert 'CIRCE_SETUP_ERROR {"code":"unsupported_distribution"}' in run(success=False).stdout
    print('Arch/Omarchy installs with pacman -S --needed (no -Sy); unknown distributions report a code.')

    release.write_text('ID=omarchy\nID_LIKE=arch\nPRETTY_NAME="Omarchy \\"4\\""\n')
    before = fingerprints()
    count = len(log.read_text().splitlines())
    result = run('--probe', extra={'FIXTURE_WAYVNC': '1', 'FIXTURE_ADMIN': '1', 'FIXTURE_RFB_PORTS': '5900,5902', **needs})
    assert fingerprints() == before, 'Probe must not change files'
    probe_calls = [json.loads(line) for line in log.read_text().splitlines()[count:]]
    assert all(c[0] != 'sudo' or c[1:] == ['-n', 'true'] for c in probe_calls) and not any(c[0] in ('apt-get', 'dnf', 'pacman', 'curl', 'flock') for c in probe_calls)
    probe = json.loads(result.stdout.split('CIRCE_PROBE_RESULT ', 1)[1])
    assert probe['os'] == {'id': 'omarchy', 'like': 'arch', 'name': 'Omarchy "4"'} and probe['packageManager'] == 'pacman'
    assert probe['sudo'] == 'password' and probe['adminGroup'] is True and probe['user'] == 'fixture'
    assert probe['circe'] == {'installed': True, 'display': 2, 'running': True, 'current': True, 'shared': None}, probe['circe']  # --display 2 above is remembered
    assert probe['systemDesktop'] is None
    vnc = {v['port']: v for v in probe['vnc']}
    assert vnc[5900] == {'port': 5900, 'display': 0, 'address': '127.0.0.1', 'loopback': True, 'rfb': True, 'process': 'wayvnc'}
    assert vnc[5905]['loopback'] is False and vnc[5905]['rfb'] is False and vnc[5902]['process'] == 'Xtigervnc' and 47989 not in vnc
    assert set(probe['sessions']) == {'Hyprland', 'wayvnc', 'sunshine', 'chrome-remote-desktop'}
    assert isinstance(probe['xDisplays'], list)
    probe = json.loads(run('--probe').stdout.split('CIRCE_PROBE_RESULT ', 1)[1])
    assert probe['sudo'] == 'passwordless' and probe['adminGroup'] is False and probe['sessions'] == []
    assert probe['withoutAdmin'] is False, 'Arch cannot borrow apt prerequisites when its own trust policy is unavailable'
    rejected = run('--without-admin', success=False)
    assert 'CIRCE_SETUP_ERROR {\"code\":\"package_unverified\"}' in rejected.stdout
    print('Probe is read-only and reports distribution, sudo mode, Circe state, existing VNC desktops, and sessions.')

    # Without administrator access: nothing runs through sudo; packages land in a private prefix.
    release.write_text('ID=ubuntu\nID_LIKE=debian\nPRETTY_NAME="Ubuntu fixture"\n')
    xkbcomp = bin_dir / 'xkbcomp'; xkbcomp.write_text('#!/bin/sh\n'); xkbcomp.chmod(0o755)
    noadmin = {'FIXTURE_SUDO_PASSWORD': 'never-used', 'CIRCE_XKBCOMP': str(xkbcomp)}
    probe = json.loads(run('--probe', extra=noadmin).stdout.split('CIRCE_PROBE_RESULT ', 1)[1])
    assert probe['withoutAdmin'] is True and probe['sudo'] == 'password'
    count = len(log.read_text().splitlines())
    result = run('--without-admin', extra=noadmin)
    calls = [json.loads(line) for line in log.read_text().splitlines()[count:]]
    assert not any(c[0] == 'sudo' and c[1:] != ['-n', 'true'] for c in calls), 'No sudo at all without administrator access'
    apt = [c for c in calls if c[0] == 'apt-get']
    assert apt and all(any(a.startswith('Dir::State::Lists=' + str(home)) for a in c) for c in apt), 'apt only uses user-owned lists'
    assert not any('install' in c and '-s' not in c for c in apt), 'apt never installs into the system'
    prefix = home / '.local/share/circe/root'
    assert any(c[0] == 'dpkg' and c[1] == '-x' and c[3].startswith(str(prefix.parent / 'runtimes/runtime.')) for c in calls), 'Unpacked into an uncommitted immutable runtime'
    assert prefix.is_dir() and not Path(str(prefix) + '.new').exists() and not Path(str(prefix) + '.old').exists(), 'Staging swapped in and cleaned up'
    assert any(c[0] == 'apt-get' and 'download' in c and any('=' in a and not a.startswith('Dir') for a in c) for c in calls), 'Exact planned versions are downloaded'
    env_file = home / '.config/circe/prefix.env'
    sourced = subprocess.run(['/bin/bash', '-c', 'source "$1"; printf %s "$CIRCE_PREFIX"', '_', str(env_file)], capture_output=True, text=True).stdout
    assert env_file.stat().st_mode & 0o777 == 0o600 and Path(sourced).parent == prefix.parent / 'runtimes' and Path(sourced).is_dir(), 'prefix.env is private and survives spaces in paths'
    report = json.loads(result.stdout.split('CIRCE_SETUP_RESULT ', 1)[1])
    assert report['withoutAdmin'] is True and report['persistent'] is True
    light = (home / '.local/libexec/circe/light-session').read_text()
    assert 'jwm -f' in light and 'prefix.env' in (home / '.local/libexec/circe/start-desktop').read_text()
    result = run('--without-admin', extra={**noadmin, 'FIXTURE_NO_SELF_LINGER': '1'})
    assert json.loads(result.stdout.split('CIRCE_SETUP_RESULT ', 1)[1])['persistent'] is False, 'No self-linger: Circe starts the desktop on connect'
    def code(result): return result.stdout.split('CIRCE_SETUP_ERROR ', 1)[1].split('\n', 1)[0]
    marker = temp / 'prefix-env-ran'
    env_text = env_file.read_text()
    env_file.write_text(env_text + f'\ntouch {shlex.quote(str(marker))}\n')
    run('--check', extra={'FIXTURE_UID': '4242'}, success=None)
    assert not marker.exists(), 'A root run never sources the account-owned prefix.env'
    run('--check')
    assert marker.exists(), 'The account itself still uses its prefix.env'
    env_file.write_text(env_text); marker.unlink()
    before = sorted(p.name for p in prefix.iterdir())
    old_runtime, old_environment = prefix.resolve(), env_file.read_bytes()
    failed = run('--without-admin', extra={**noadmin, 'FIXTURE_HEALTH_FAIL': '1'}, success=False)
    assert code(failed) == '{\"code\":\"runtime_unhealthy\"}', failed
    assert prefix.resolve() == old_runtime and env_file.read_bytes() == old_environment, 'A failing real candidate health probe never promotes or replaces the active environment'
    assert code(run('--without-admin', extra={**noadmin, 'FIXTURE_LOCKED': '1'}, success=False)) == '{"code":"setup_running"}'
    assert code(run('--without-admin', extra={**noadmin, 'FIXTURE_DISK_FULL': '1'}, success=False)) == '{"code":"disk_full"}'
    assert code(run('--without-admin', extra={**noadmin, 'FIXTURE_APT_MISSING': '1'}, success=False)) == '{"code":"package_unavailable"}'
    failed = run('--without-admin', extra={**noadmin, 'FIXTURE_APT_BROKEN': '1'}, success=False)
    assert code(failed) == '{"code":"package_unavailable"}' and 'held broken packages' in failed.stdout + failed.stderr
    assert code(run('--without-admin', extra={**noadmin, 'FIXTURE_APT_LIBC': '1'}, success=False)) == '{"code":"system_outdated"}', 'A newer C library is never used privately'
    assert sorted(p.name for p in prefix.iterdir()) == before, 'A failed repair leaves the working desktop untouched'
    release.write_text('ID=gentoo\nPRETTY_NAME="Gentoo"\n')
    assert 'CIRCE_SETUP_ERROR {"code":"unsupported_distribution"}' in run('--without-admin', extra=noadmin, success=False).stdout, 'Honest refusal'
    release.write_text('ID=ubuntu\nID_LIKE=debian\nPRETTY_NAME="Ubuntu fixture"\n')
    env_file.unlink()
    print('Without administrator access: no sudo, user-owned package lists, private prefix, JWM session, honest persistence.')
print('Linux setup fixtures passed (no real packages, services, cloud resources, or network connections).')
