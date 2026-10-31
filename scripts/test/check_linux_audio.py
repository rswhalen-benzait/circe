#!/usr/bin/env python3
"""Audio helper fixtures: preflight failures cannot contaminate PCM fallback stdout."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'scripts/linux/circe-audio.sh'
OGG = b'OggS\x00\x02fixture'
MOCK = r'''#!/usr/bin/env python3
import json,os,pathlib,sys
name=pathlib.Path(sys.argv[0]).name;args=sys.argv[1:]
with open(os.environ['FIXTURE_LOG'],'a') as f: f.write(json.dumps({'command':name,'args':args,'pulse':os.environ.get('PULSE_SERVER')})+'\n')
if name=='uname': print('Linux')
elif name=='timeout': os.execvp(args[1],args[1:])
elif name=='pactl': sys.exit(1 if os.environ.get('FIXTURE_PULSE_FAIL') else 0)
elif name=='ffmpeg':
    if '-devices' in args:
        if not os.environ.get('FIXTURE_NO_PULSE'): print(' D pulse PulseAudio input')
    elif '-muxers' in args:
        if not os.environ.get('FIXTURE_NO_OGG'): print(' E ogg Ogg')
    elif '-encoders' in args:
        if not os.environ.get('FIXTURE_NO_OPUS'): print(' A..... libopus Opus')
    elif 'lavfi' in args:
        sys.stdout.buffer.write(b'probe bytes must never escape')
        sys.exit(1 if os.environ.get('FIXTURE_PROBE_FAIL') else 0)
    else:
        sys.stdout.buffer.write(b'OggS\x00\x02fixture');sys.stdout.buffer.flush()
        if os.environ.get('FIXTURE_HOLD'):
            pathlib.Path(os.environ['FIXTURE_PID']).write_text(str(os.getpid()))
            os.execl('/bin/sleep','sleep','60')
        sys.exit(int(os.environ.get('FIXTURE_EXIT','0')))
'''

with tempfile.TemporaryDirectory(prefix='circe-audio-check.') as directory:
    temp=Path(directory);bins=temp/'bin';bins.mkdir();home=temp/'home';home.mkdir();runtime=temp/'runtime';runtime.mkdir()
    for name in ('uname','timeout','pactl','ffmpeg'):
        path=bins/name;path.write_text(MOCK);path.chmod(0o755)
    log=temp/'calls.jsonl'
    env={**os.environ,'PATH':f'{bins}:/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),'XDG_RUNTIME_DIR':str(runtime),'FIXTURE_LOG':str(log)}
    env.pop('PULSE_SERVER',None)
    def run(*args,extra=None,code=0):
        before=len(log.read_text().splitlines()) if log.exists() else 0
        p=subprocess.run(['/bin/bash',str(HELPER),*args],env={**env,**(extra or {})},capture_output=True,timeout=8)
        assert p.returncode==code,(p.returncode,p.stderr.decode())
        calls=[json.loads(line) for line in log.read_text().splitlines()[before:]]
        return p,calls
    p,calls=run()
    assert p.stdout==OGG,'Stream stdout must never include probes or diagnostics'
    capture=next(call for call in calls if 'pulse' in call['args'])
    args=capture['args']
    for flag,value in [('-i','@DEFAULT_MONITOR@'),('-sample_rate','48000'),('-channels','2'),('-fragment_size','1920'),('-frame_duration','10'),('-page_duration','20000'),('-b:a','128k'),('-application','lowdelay'),('-mapping_family','0')]:
        assert args[args.index(flag)+1]==value
    assert capture['pulse']==f'unix:{runtime}/pulse/native'
    p,calls=run('--check','--bitrate-kbps','96',extra={'PULSE_SERVER':'unix:/custom/pulse'})
    config=json.loads(p.stdout)
    assert config['frameSamples']==480 and config['channels']==2 and config['sampleRate']==48000 and config['bitrateKbps']==96
    assert not any('pulse' in call['args'] for call in calls),'Check must not start live audio capture'
    assert next(call for call in calls if call['command']=='pactl')['pulse']=='unix:/custom/pulse'
    print('Opus configuration, monitor source, Pulse environment, stdout isolation, and read-only check passed.')
    for key in ('FIXTURE_PULSE_FAIL','FIXTURE_NO_PULSE','FIXTURE_NO_OGG','FIXTURE_NO_OPUS','FIXTURE_PROBE_FAIL'):
        p,calls=run(extra={key:'1'},code=69)
        assert not p.stdout and not any('pulse' in call['args'] for call in calls),key
    p,calls=run(extra={'FIXTURE_EXIT':'23'},code=75)
    assert p.stdout==OGG and sum('pulse' in call['args'] for call in calls)==1
    for args in [('--bitrate-kbps','31'),('--bitrate-kbps','257'),('--bitrate-kbps','x'),('--bitrate-kbps',),('--unknown',)]:
        p,_=run(*args,code=64);assert not p.stdout
    print('All exit-69 paths emit zero stdout; live failures exit 75 without appending another format.')
    pid_file=temp/'child.pid';child=None
    process=subprocess.Popen(['/bin/bash',str(HELPER)],env={**env,'FIXTURE_HOLD':'1','FIXTURE_PID':str(pid_file)},stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try:
        deadline=time.time()+4
        while not pid_file.exists() and time.time()<deadline: time.sleep(0.03)
        assert pid_file.exists();child=int(pid_file.read_text())
        process.terminate();process.wait(timeout=3);assert process.returncode==0
        try: os.kill(child,0)
        except ProcessLookupError: child=None
        assert child is None,'Cancelled helper left its encoder running'
    finally:
        if process.poll() is None: os.killpg(process.pid,signal.SIGKILL);process.wait()
        if child:
            try: os.kill(child,signal.SIGKILL)
            except ProcessLookupError: pass
    print('Cancellation reaps the owned encoder.')
print('Linux audio helper fixtures passed without real audio devices or network access.')
