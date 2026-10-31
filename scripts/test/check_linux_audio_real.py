#!/usr/bin/env python3
"""Verify real libopus/Ogg packets and live page delivery, using paced PCM instead of PulseAudio."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT=Path(__file__).resolve().parents[2]
REAL=os.environ.get('CIRCE_TEST_FFMPEG') or shutil.which('ffmpeg')
if not REAL: raise SystemExit('Set CIRCE_TEST_FFMPEG to a real FFmpeg executable with libopus.')
REAL=str(Path(REAL).resolve())
BRIDGE=r'''#!/usr/bin/env python3
import math,os,pathlib,struct,subprocess,sys,time
args=sys.argv[1:]
if '-devices' in args: print(' D pulse Fixture PulseAudio input');sys.exit(0)
if 'pulse' not in args: os.execv(os.environ['CIRCE_TEST_FFMPEG'],[os.environ['CIRCE_TEST_FFMPEG'],*args])
index=args.index('-f');end=args.index('-i')+2
replacement=['-f','s16le','-ar','48000','-ac','2','-i','pipe:0']
p=subprocess.Popen([os.environ['CIRCE_TEST_FFMPEG'],*args[:index],*replacement,*args[end:]],stdin=subprocess.PIPE)
try:
    start=time.monotonic();pathlib.Path(os.environ['CIRCE_TEST_AUDIO_START']).write_text(str(time.time()))
    for block in range(120):
        data=b''.join(struct.pack('<hh',*[int(10000*math.sin(2*math.pi*440*(block*480+i)/48000))]*2) for i in range(480))
        p.stdin.write(data);p.stdin.flush()
        time.sleep(max(0,start+(block+1)*0.01-time.monotonic()))
    p.stdin.close();sys.exit(p.wait())
finally:
    if p.poll() is None: p.terminate();p.wait()
'''

with tempfile.TemporaryDirectory(prefix='circe-audio-real.') as directory:
    temp=Path(directory);bins=temp/'bin';bins.mkdir();home=temp/'home';home.mkdir();runtime=temp/'runtime';runtime.mkdir()
    for name,source in {
        'ffmpeg':BRIDGE,
        'uname':'#!/bin/sh\necho Linux\n',
        'timeout':'#!/bin/sh\nshift\nexec "$@"\n',
        'pactl':'#!/bin/sh\nexit 0\n',
    }.items():
        path=bins/name;path.write_text(source);path.chmod(0o755)
    start_file=temp/'start'
    env={**os.environ,'PATH':f'{bins}:/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),'XDG_RUNTIME_DIR':str(runtime),'CIRCE_TEST_FFMPEG':REAL,'CIRCE_TEST_AUDIO_START':str(start_file)}
    p=subprocess.Popen(['/bin/bash',str(ROOT/'scripts/linux/circe-audio.sh')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    chunks=[]
    def read():
        while True:
            data=p.stdout.read1(65536)
            if not data: break
            # Older macOS Python uses a process-local monotonic epoch. This
            # short cross-process startup measurement needs a shared clock.
            chunks.append((time.time(),data))
    reader=threading.Thread(target=read);reader.start()
    try: p.wait(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGKILL);p.wait();raise
    finally: reader.join(timeout=3)
    diagnostics=p.stderr.read().decode()
    assert p.returncode==0,diagnostics
    configs=[json.loads(line.split(' ',1)[1]) for line in diagnostics.splitlines() if line.startswith('CIRCE_AUDIO_CONFIG ')]
    assert len(configs)==1 and configs[0]['frameSamples']==480
    buffer=bytearray();partial=bytearray();packets=[];pages=[];last_sequence=-1
    for arrival,data in chunks:
        buffer.extend(data)
        while len(buffer)>=27:
            assert buffer[:4]==b'OggS' and buffer[4]==0,'Unexpected stdout or Ogg version'
            count=buffer[26]
            if len(buffer)<27+count: break
            laces=buffer[27:27+count];length=27+count+sum(laces)
            if len(buffer)<length: break
            sequence=int.from_bytes(buffer[18:22],'little');assert sequence==last_sequence+1
            last_sequence=sequence
            granule=int.from_bytes(buffer[6:14],'little');q=27+count
            before=len(packets)
            for lace in laces:
                partial.extend(buffer[q:q+lace]);q+=lace
                if lace<255: packets.append(bytes(partial));partial.clear()
            if len(packets)>max(2,before): pages.append((arrival,granule,len(packets)-max(2,before)))
            del buffer[:length]
    assert not buffer and not partial,'Truncated Ogg page or packet'
    assert packets[0][:8]==b'OpusHead' and packets[0][9]==2 and packets[0][18]==0
    assert int.from_bytes(packets[0][12:16],'little')==48000 and packets[1][:8]==b'OpusTags'
    for packet in packets[2:]:
        config=packet[0]>>3;code=packet[0]&3
        duration=([10,20,40,60][config&3] if config<12 else [10,20][config&1] if config<16 else [2.5,5,10,20][config&3])
        count=1 if code==0 else 2 if code in (1,2) else packet[1]&63
        assert duration*count==10,'Client expects 480-sample/10 ms packets'
    assert len(packets[2:])>=120 and max(page[2] for page in pages)<=3,'Audio is batching into large pages'
    assert pages[-1][0]-pages[0][0]>0.7,'Ogg pages were buffered until EOF'
    initial=pages[0][0]-float(start_file.read_text())
    assert 0<=initial<0.75,('Unexpected startup buffering',initial)
    output=temp/'audio.ogg';output.write_bytes(b''.join(data for _,data in chunks))
    decoded=subprocess.run([REAL,'-v','error','-i',str(output),'-f','s16le','pipe:1'],capture_output=True,check=True).stdout
    assert abs(len(decoded)//4-57600)<=480,'Decoded duration differs from 1.2 s source'
    # Nominal 128 kb/s plus page/header overhead; the constrained VBR fixture should stay well below PCM.
    rate=output.stat().st_size*8/1.2/1000
    assert rate<200,rate
    print(f'Real Opus/Ogg passed: {len(packets)-2} ten-ms packets; maximum {max(page[2] for page in pages)} packets/page; first audio page {initial*1000:.0f} ms after source starts; {rate:.1f} kb/s with Ogg overhead.')
print('This checks actual encoding and incremental mux delivery, not Linux PulseAudio latency or WAN jitter.')
