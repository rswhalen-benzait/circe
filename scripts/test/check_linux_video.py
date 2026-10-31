#!/usr/bin/env python3
"""Check the Linux video wrapper with local command fixtures; no X server or GPU needed."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
WRAPPER = ROOT / 'scripts/linux/circe-video.sh'
FLV_HEADER = b'FLV\x01\x01\x00\x00\x00\x09\x00\x00\x00\x00'
MOCK = r'''#!/usr/bin/env python3
import json,os,pathlib,sys,signal,time
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['FIXTURE_LOG'],'a') as f: f.write(json.dumps({'command':name,'args':args,'xauthority':os.environ.get('XAUTHORITY')})+'\n')
if name=='uname': print('Linux')
elif name=='nproc': print(os.environ.get('FIXTURE_CPUS','2'))
elif name=='timeout': os.execvp(args[1],args[1:])
elif name=='xdpyinfo':
    if os.environ.get('FIXTURE_DISPLAY_FAIL'): print('Invalid MIT-MAGIC-COOKIE',file=sys.stderr);sys.exit(1)
    print('screen #0:\n  dimensions: '+os.environ.get('FIXTURE_SIZE','1920x1080')+' pixels')
elif name=='ffmpeg':
    if '-devices' in args:
        if not os.environ.get('FIXTURE_NO_X11'): print(' D  x11grab  X11 capture')
    elif '-muxers' in args: print(' E  flv      FLV output')
    elif '-encoders' in args:
        print(' V..... h264_nvenc NVIDIA H264')
        if not os.environ.get('FIXTURE_NO_X264'): print(' V..... libx264 software H264')
    elif 'lavfi' in args:
        if 'h264_nvenc' in args and not os.environ.get('FIXTURE_NVENC'): print('No usable NVIDIA driver',file=sys.stderr);sys.exit(1)
    else:
        sys.stdout.buffer.write(b'FLV\x01\x01\x00\x00\x00\x09\x00\x00\x00\x00');sys.stdout.buffer.flush()
        if os.environ.get('FIXTURE_HOLD'):
            if os.environ.get('FIXTURE_IGNORE_TERM'): signal.signal(signal.SIGTERM,signal.SIG_IGN)
            pathlib.Path(os.environ['FIXTURE_PID']).write_text(str(os.getpid()))
            if os.environ.get('FIXTURE_IGNORE_TERM'):
                while True: time.sleep(1)
            os.execl('/bin/sleep','sleep','60')
        sys.exit(int(os.environ.get('FIXTURE_LIVE_EXIT','0')))
'''

with tempfile.TemporaryDirectory(prefix='circe-video-check.') as directory:
    temp=Path(directory); bins=temp/'bin'; bins.mkdir(); home=temp/'home'; home.mkdir(); runtime=temp/'runtime';runtime.mkdir()
    (runtime/'circe-Xauthority').write_text('fixture-cookie')
    (home/'.config/circe').mkdir(parents=True)
    (home/'.config/circe/host.conf').write_text('DISPLAY_NUMBER=3\n')
    log=temp/'calls.jsonl'
    for name in ['uname','nproc','timeout','xdpyinfo','ffmpeg']:
        path=bins/name;path.write_text(MOCK);path.chmod(0o755)
    env={**os.environ,'PATH':f'{bins}:/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),'XDG_RUNTIME_DIR':str(runtime),'FIXTURE_LOG':str(log)}
    env.pop('XAUTHORITY',None)
    def run(*args,extra=None,code=0):
        before=len(log.read_text().splitlines()) if log.exists() else 0
        p=subprocess.run(['/bin/bash',str(WRAPPER),*args],env={**env,**(extra or {})},capture_output=True,timeout=8)
        assert p.returncode==code,(p.returncode,p.stderr.decode())
        calls=[json.loads(line) for line in log.read_text().splitlines()[before:]]
        return p,calls
    def config(p):
        lines=[line[len('CIRCE_VIDEO_CONFIG '):] for line in p.stderr.decode().splitlines() if line.startswith('CIRCE_VIDEO_CONFIG ')]
        assert len(lines)==1,p.stderr
        return json.loads(lines[0])
    p,calls=run()
    assert p.stdout==FLV_HEADER
    c=config(p)
    assert (c['encoder'],c['fps'],c['threads'],c['bitrateKbps'])==('x264',20,1,6000)
    capture=next(call for call in calls if call['command']=='ffmpeg' and 'x11grab' in call['args'])
    args=capture['args']
    for flag,value in [('-draw_mouse','0'),('-bf','0'),('-g','200'),('-bufsize','1500k'),('-flush_packets','1'),('-f','x11grab'),('-use_wallclock_as_timestamps','1')]: assert args[args.index(flag)+1]==value
    assert '-copyts' in args and '-start_at_zero' in args and 'flv' in args and 'pipe:1' in args
    assert args[args.index('-i')+1]==':3.0' and capture['xauthority']==str(runtime/'circe-Xauthority')
    assert 'no_duration_filesize' in args and 'yuv420p' in args and '-intra-refresh' not in args
    assert any('keyint=200:min-keyint=20:scenecut=0' in arg for arg in args)
    p,_=run('--check',extra={'FIXTURE_CPUS':'4'})
    c=json.loads(p.stdout)
    assert (c['fps'],c['threads'],c['encoder'])==(30,2,'x264')
    assert 'CIRCE_VIDEO_CONFIG' not in p.stderr.decode()
    print('CPU defaults, Xauthority, wallclock-derived PTS, 10-second GOP, FLV stdout purity, and check mode passed.')

    p,calls=run('--check',extra={'FIXTURE_NVENC':'1'})
    c=json.loads(p.stdout)
    assert (c['encoder'],c['fps'],c['bitrateKbps'])==('nvenc',60,12000)
    assert any('h264_nvenc' in call['args'] and 'lavfi' in call['args'] for call in calls)
    p,calls=run(extra={'FIXTURE_NVENC':'1'})
    args=next(call['args'] for call in calls if 'x11grab' in call['args'])
    assert args[args.index('-g')+1]=='600' and args[args.index('-bufsize')+1]=='3000k'
    p,_=run('--encoder','nvenc',code=69)
    assert not p.stdout and b'encoder_unavailable' in p.stderr
    p,_=run('--check',extra={'FIXTURE_NO_X264':'1'},code=69)
    assert not p.stdout
    print('Real-encode probe selection and explicit NVENC failure passed; software fallback occurs before stream bytes.')

    p,calls=run('--display',':1.0','--fps','60','--threads','3','--bitrate-kbps','9000','--max-width','1280','--max-height','720')
    c=config(p)
    assert (c['fps'],c['threads'],c['bitrateKbps'],c['width'],c['height'])==(60,3,9000,1280,720)
    p,_=run('--check',extra={'FIXTURE_SIZE':'641x479'})
    c=json.loads(p.stdout);assert (c['sourceWidth'],c['sourceHeight'],c['width'],c['height'])==(641,479,642,480)
    p,calls=run('--fps','1','--bitrate-kbps','1000')
    c=config(p); assert c['fps']==1
    args=next(call['args'] for call in calls if 'x11grab' in call['args'])
    assert args[args.index('-bufsize')+1]=='1000k', 'Explicit low FPS still needs room for one frame'
    print('Explicit overrides, aspect-preserving limits, odd-size padding, and low-FPS operation passed.')

    for args in [('--fps','0'),('--fps','121'),('--threads','0'),('--bitrate-kbps','10'),('--encoder','anything'),('--display','host:1'),('--max-width','2'),('--fps','--help'),('--unknown',)]:
        p,_=run(*args,code=64);assert not p.stdout
    p,_=run('--check',extra={'FIXTURE_DISPLAY_FAIL':'1'},code=77);assert not p.stdout
    p,_=run('--check',extra={'FIXTURE_NO_X11':'1'},code=69);assert not p.stdout
    p,calls=run(extra={'FIXTURE_NVENC':'1','FIXTURE_LIVE_EXIT':'23'},code=75)
    assert p.stdout==FLV_HEADER and len([call for call in calls if 'x11grab' in call['args']])==1
    print('Invalid arguments, X access failure, missing capture support, and live encoder failure exit codes passed.')

    for stubborn in (False,True):
        pid_file=temp/f'child-{stubborn}.pid'
        extra={'FIXTURE_IGNORE_TERM':'1'} if stubborn else {}
        wrapper=subprocess.Popen(['/bin/bash',str(WRAPPER)],env={**env,**extra,'FIXTURE_HOLD':'1','FIXTURE_PID':str(pid_file)},stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        child=None
        try:
            deadline=time.time()+4
            while not pid_file.exists() and time.time()<deadline: time.sleep(0.03)
            assert pid_file.exists(),'Live encoder did not start'
            child=int(pid_file.read_text())
            started=time.monotonic();wrapper.terminate();wrapper.wait(timeout=2.5)
            assert wrapper.returncode==0 and time.monotonic()-started<2
            try: os.kill(child,0)
            except ProcessLookupError: child=None
            assert child is None,'Cancelled wrapper left its encoder running'
        finally:
            if wrapper.poll() is None: os.killpg(wrapper.pid,signal.SIGKILL);wrapper.wait()
            if child:
                try: os.kill(child,signal.SIGKILL)
                except ProcessLookupError: pass
    print('Cancellation reaps normal and TERM-ignoring encoders within two seconds.')
print('Linux video wrapper fixtures passed; no real X display, GPU, network, or cloud resources used.')
