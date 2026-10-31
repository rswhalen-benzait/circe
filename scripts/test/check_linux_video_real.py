#!/usr/bin/env python3
"""Exercise real x264/FLV encoding locally, substituting timed PPM frames for an X server."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parents[2]
REAL=os.environ.get('CIRCE_TEST_FFMPEG') or shutil.which('ffmpeg')
if not REAL: raise SystemExit('Set CIRCE_TEST_FFMPEG to a real FFmpeg executable (with libx264).')
REAL=str(Path(REAL).resolve())
BRIDGE=r'''#!/usr/bin/env python3
import os,subprocess,sys,time
args=sys.argv[1:]
if '-devices' in args:
    print(' D x11grab Fixture input bridge');sys.exit(0)
if 'x11grab' not in args: os.execv(os.environ['CIRCE_TEST_FFMPEG'],[os.environ['CIRCE_TEST_FFMPEG'],*args])
index=args.index('-f');end=args.index('-i')+2
before=args[:index]
# Remove the queue option only if it was tied to capture? Keep it: this must test the real path.
input_args=['-f','image2pipe','-framerate','30','-vcodec','ppm','-probesize','32','-analyzeduration','0','-i','pipe:0']
p=subprocess.Popen([os.environ['CIRCE_TEST_FFMPEG'],*before,*input_args,*args[end:]],stdin=subprocess.PIPE)
try:
    for i in range(16):
        if i==7: time.sleep(0.65)
        color=bytes((240,20,30)) if i<7 else bytes((20,40,230))
        p.stdin.write(b'P6\n640 480\n255\n'+color*(640*480));p.stdin.flush();time.sleep(1/30)
    p.stdin.close();sys.exit(p.wait())
finally:
    if p.poll() is None: p.terminate();p.wait()
'''

with tempfile.TemporaryDirectory(prefix='circe-video-real.') as directory:
    temp=Path(directory);bins=temp/'bin';bins.mkdir();home=temp/'home';home.mkdir();runtime=temp/'runtime';runtime.mkdir()
    for name,text in {
        'ffmpeg':BRIDGE,
        'uname':'#!/bin/sh\necho Linux\n',
        'nproc':'#!/bin/sh\necho 4\n',
        'xdpyinfo':'#!/bin/sh\necho "  dimensions: 640x480 pixels"\n',
        'timeout':'#!/bin/sh\nshift\nexec "$@"\n',
    }.items():
        path=bins/name;path.write_text(text);path.chmod(0o755)
    env={**os.environ,'PATH':f'{bins}:/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),'XDG_RUNTIME_DIR':str(runtime),'CIRCE_TEST_FFMPEG':REAL}
    process=subprocess.Popen(['/bin/bash',str(ROOT/'scripts/linux/circe-video.sh'),'--encoder','x264','--fps','30','--bitrate-kbps','3000'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try: data,diagnostics=process.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL);process.wait();raise
    assert process.returncode==0,diagnostics.decode()
    assert data[:3]==b'FLV' and data[4]==1,'Expected video-only FLV, no stdout diagnostics'
    configs=[json.loads(line.split(' ',1)[1]) for line in diagnostics.decode().splitlines() if line.startswith('CIRCE_VIDEO_CONFIG ')]
    assert len(configs)==1 and configs[0]['encoder']=='x264'
    offset=int.from_bytes(data[5:9],'big')+4
    frames=[];sequence=0
    while offset<len(data):
        assert offset+15<=len(data),'Truncated tag'
        kind=data[offset];length=int.from_bytes(data[offset+1:offset+4],'big')
        millis=int.from_bytes(data[offset+4:offset+7],'big')|(data[offset+7]<<24)
        body=data[offset+11:offset+11+length]
        assert len(body)==length and int.from_bytes(data[offset+11+length:offset+15+length],'big')==11+length
        assert kind!=8,'Audio must not be muxed into this channel'
        if kind==9:
            assert body[0]&15==7
            if body[1]==0:
                sequence+=1;assert body[5]==1 and (body[9]&3)+1==4,'Expected AVC config with 4-byte NAL lengths'
            elif body[1]==1:
                assert body[2:5]==b'\0\0\0','B-frame composition offset must be zero'
                frames.append(millis)
        offset+=15+length
    assert sequence>=1 and len(frames)==16,(sequence,len(frames),diagnostics.decode())
    gaps=[b-a for a,b in zip(frames,frames[1:])]
    assert frames[0]<1000,frames
    assert max(gaps)>=500,('Capture-time stall was replaced with a frame counter',frames)
    assert all(gap>=0 for gap in gaps),frames
    print(f'Real x264 → FLV passed: {len(frames)} complete AVC frames, config present, zero composition offsets, first PTS={frames[0]} ms, capture gap={max(gaps)} ms.')
    output=temp/'video.flv';output.write_bytes(data)
    decoded=subprocess.run([REAL,'-v','error','-i',str(output),'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','pipe:1'],capture_output=True,check=True)
    pixel=decoded.stdout[:3]
    assert all(abs(a-b)<=5 for a,b in zip(pixel,(240,20,30))),tuple(pixel)
    print(f'Explicit desktop color conversion decoded first pixel as {tuple(pixel)} (source 240,20,30).')
    # The live shim execs FFmpeg (no intermediary writer). A finite source does
    # not exercise FFmpeg's occasionally stalled first-signal shutdown.
    live_env={**env,'PATH':f'{ROOT}/scripts/test/realvideo:'+env['PATH']}
    with tempfile.TemporaryFile() as stream:
        live=subprocess.Popen(['/bin/bash',str(ROOT/'scripts/linux/circe-video.sh'),'--encoder','x264'],env=live_env,stdout=stream,stderr=subprocess.PIPE,start_new_session=True)
        children=[]
        try:
            deadline=time.monotonic()+8
            while os.fstat(stream.fileno()).st_size<1024 and live.poll() is None and time.monotonic()<deadline: time.sleep(0.03)
            assert os.fstat(stream.fileno()).st_size>=1024,'Live FFmpeg did not start'
            children=[int(pid) for pid in subprocess.check_output(['pgrep','-P',str(live.pid)],text=True).split()]
            assert children,'Expected an owned live FFmpeg process'
            started=time.monotonic();live.terminate();live.wait(timeout=2.5)
            elapsed=time.monotonic()-started
            assert live.returncode==0 and elapsed<2,(live.returncode,elapsed)
            for pid in children:
                try: os.kill(pid,0)
                except ProcessLookupError: continue
                raise AssertionError(f'Cancelled wrapper left real FFmpeg {pid} running')
            children=[]
            print(f'Real FFmpeg cancellation reaped wrapper and encoder in {elapsed:.2f} s.')
        finally:
            if live.poll() is None: os.killpg(live.pid,signal.SIGKILL);live.wait()
            for pid in children:
                try: os.kill(pid,signal.SIGKILL)
                except ProcessLookupError: pass
print('This verifies encoding/muxing/timestamp behavior, not Linux XShm capture or GPU performance.')
