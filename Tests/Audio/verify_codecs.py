"""Integration test original decode, MP3 trimming, SRC, analysis, seek and render."""
import argparse
import ctypes as C
import json
from pathlib import Path
import subprocess
import sys
import time
import numpy as np
from verify_dsp import library, EQ, Band

class Info(C.Structure):
    _fields_=[("sampleRate",C.c_double),("duration",C.c_double),("channels",C.c_int32),("bitsPerSample",C.c_int32),("frames",C.c_uint64)]
class Analysis(C.Structure):
    _fields_=[("samplePeak",C.c_double),("truePeak",C.c_double),("inputPeak",C.c_double),("effectivePreampDB",C.c_double),("safetyDB",C.c_double),("frames",C.c_uint64)]
READ=C.CFUNCTYPE(C.c_int64,C.c_void_p,C.c_uint64,C.c_void_p,C.c_size_t)
class ByteSource(C.Structure):
    _fields_=[("context",C.c_void_p),("read",READ),("length",C.c_uint64)]
def run(*args):return subprocess.check_output(list(map(str,args)),stderr=subprocess.PIPE)
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--library",required=True);parser.add_argument("--report",default="TestResults/codecs.json");args=parser.parse_args()
    lib=library(args.library)
    lib.pt_decoder_open.argtypes=[C.c_char_p];lib.pt_decoder_open.restype=C.c_void_p
    lib.pt_decoder_info.argtypes=[C.c_void_p];lib.pt_decoder_info.restype=Info
    lib.pt_decoder_read.argtypes=[C.c_void_p,C.c_void_p,C.c_size_t];lib.pt_decoder_read.restype=C.c_int64
    lib.pt_decoder_close.argtypes=[C.c_void_p]
    lib.pt_analyze.argtypes=[C.c_char_p,C.c_double,C.POINTER(EQ),C.POINTER(Analysis)];lib.pt_analyze.restype=C.c_int
    lib.pt_analyze_sequence_cancelable.argtypes=[C.POINTER(C.c_char_p),C.c_size_t,C.c_double,C.POINTER(EQ),C.POINTER(Analysis),C.c_void_p,C.c_void_p];lib.pt_analyze_sequence_cancelable.restype=C.c_int
    lib.pt_player_create.argtypes=[C.c_char_p,C.c_double,C.POINTER(EQ),C.c_double];lib.pt_player_create.restype=C.c_void_p
    lib.pt_player_pause.argtypes=[C.c_void_p,C.c_int];lib.pt_player_render.argtypes=[C.c_void_p,C.c_void_p,C.c_size_t];lib.pt_player_render.restype=C.c_size_t
    lib.pt_player_seek.argtypes=[C.c_void_p,C.c_double];lib.pt_player_seek.restype=C.c_int
    lib.pt_player_state.argtypes=[C.c_void_p];lib.pt_player_state.restype=C.c_int
    lib.pt_player_destroy.argtypes=[C.c_void_p];lib.pt_last_error.restype=C.c_char_p
    lib.pt_player_create_source.argtypes=[ByteSource,C.c_char_p,C.c_double,C.POINTER(EQ)];lib.pt_player_create_source.restype=C.c_void_p
    lib.pt_source_info.argtypes=[ByteSource,C.c_char_p,C.POINTER(Info)];lib.pt_source_info.restype=C.c_int
    lib.pt_player_enqueue.argtypes=[C.c_void_p,C.c_char_p];lib.pt_player_enqueue.restype=C.c_int
    lib.pt_player_track_index.argtypes=[C.c_void_p];lib.pt_player_track_index.restype=C.c_uint64
    lib.pt_player_set_eq_revision.argtypes=[C.c_void_p,C.POINTER(EQ),C.c_double];lib.pt_player_set_eq_revision.restype=C.c_uint64
    lib.pt_player_eq_revision.argtypes=[C.c_void_p];lib.pt_player_eq_revision.restype=C.c_uint64
    root=Path(".build/fixtures");root.mkdir(parents=True,exist_ok=True)
    fs=44100;n=fs*2;t=np.arange(n)/fs;rng=np.random.default_rng(32)
    pcm=np.round(np.column_stack([.3*np.sin(2*np.pi*997*t),rng.uniform(-.02,.02,n)])*(2**23-1)).astype('<i4')
    raw=root/"source.s32";raw.write_bytes((pcm<<8).tobytes())
    flac=root/"original.flac";mp3=root/"encoded.mp3"
    run('ffmpeg','-y','-f','s32le','-ar',str(fs),'-ac','2','-i',raw,'-c:a','flac','-sample_fmt','s32',flac)
    run('ffmpeg','-y','-i',flac,'-c:a','libmp3lame','-q:a','0',mp3)
    def decode(path):
        d=lib.pt_decoder_open(str(path.resolve()).encode());assert d,lib.pt_last_error()
        info=lib.pt_decoder_info(d);chunks=[]
        try:
            while True:
                buf=np.empty((4096,info.channels),dtype=np.float64)
                count=lib.pt_decoder_read(d,buf.ctypes.data,len(buf));assert count>=0,lib.pt_last_error()
                if count==0:break
                chunks.append(buf[:count].copy())
        finally:lib.pt_decoder_close(d)
        return info,np.concatenate(chunks)
    info,decoded=decode(flac)
    assert len(decoded)==n and np.array_equal(decoded,pcm.astype(np.float64)/2**23)
    mp3_info,mp3_pcm=decode(mp3);assert len(mp3_pcm)==n,(len(mp3_pcm),n)
    assert mp3_info.sampleRate==fs and np.isfinite(mp3_pcm).all()
    eq=EQ(1,1,0);eq.bands[0]=Band(0,1,1000,1,24)
    analysis=Analysis();assert lib.pt_analyze(str(flac.resolve()).encode(),48000,C.byref(eq),C.byref(analysis)),lib.pt_last_error()
    assert analysis.truePeak>=analysis.samplePeak and analysis.safetyDB<0
    assert analysis.truePeak*10**(analysis.safetyDB/20)<=10**(-1/20)*(1+1e-12)
    p=lib.pt_player_create(str(flac.resolve()).encode(),48000,C.byref(eq),analysis.effectivePreampDB);assert p,lib.pt_last_error()
    try:
        lib.pt_player_pause(p,0);samples=[];deadline=time.time()+15
        while time.time()<deadline:
            buf=np.empty((512,2),np.float32);count=lib.pt_player_render(p,buf.ctypes.data,len(buf))
            if count:samples.append(buf[:count].copy())
            if lib.pt_player_state(p)==2:break
            assert lib.pt_player_state(p)!=-1
            time.sleep(.002)
        rendered=np.concatenate(samples);assert abs(len(rendered)-96000)<4,len(rendered)
        assert np.max(np.abs(rendered))<=10**(-1/20)+1e-5
        assert lib.pt_player_seek(p,.5)==1
    finally:lib.pt_player_destroy(p)
    # Boundary states must match a single continuous original, including the SRC phase.
    # A resonant low-pass makes independent per-file peak scans insufficient.
    split=15013
    sequence_pcm=np.zeros((split*2,2),dtype='<i4')
    sequence_pcm[split-1000:split]=int(.63*(2**23-1))
    sequence_pcm[split:split+5000]=int(-.63*(2**23-1))
    files=[]
    for name,data in [('part-a',sequence_pcm[:split]),('part-b',sequence_pcm[split:]),('joined',sequence_pcm)]:
        source_raw=root/(name+'.s32');source_raw.write_bytes((data<<8).tobytes());audio=root/(name+'.flac')
        run('ffmpeg','-y','-f','s32le','-ar',str(fs),'-ac','2','-i',source_raw,'-c:a','flac','-sample_fmt','s32',audio);files.append(audio)
    boundary_eq=EQ(1,1,0);boundary_eq.bands[0]=Band(3,1,40,10,0)
    pointers=(C.c_char_p*2)(*[str(file.resolve()).encode() for file in files[:2]])
    continuous=Analysis();whole=Analysis();individual=[]
    assert lib.pt_analyze_sequence_cancelable(pointers,2,48000,C.byref(boundary_eq),C.byref(continuous),None,None),lib.pt_last_error()
    assert lib.pt_analyze(str(files[2].resolve()).encode(),48000,C.byref(boundary_eq),C.byref(whole))
    assert continuous.frames==whole.frames
    assert abs(continuous.truePeak-whole.truePeak)<1e-12,(continuous.truePeak,whole.truePeak)
    for file in files[:2]:
        peak=Analysis();assert lib.pt_analyze(str(file.resolve()).encode(),48000,C.byref(boundary_eq),C.byref(peak));individual.append(peak.truePeak)
    def playback(file,next_file=None):
        player=lib.pt_player_create(str(file.resolve()).encode(),48000,C.byref(boundary_eq),continuous.effectivePreampDB);assert player
        try:
            if next_file:assert lib.pt_player_enqueue(player,str(next_file.resolve()).encode())
            lib.pt_player_pause(player,0);chunks=[];deadline=time.time()+10
            while time.time()<deadline:
                data=np.empty((251,2),np.float32);got=lib.pt_player_render(player,data.ctypes.data,len(data))
                if got:chunks.append(data[:got].copy())
                state=lib.pt_player_state(player);assert state!=-1,lib.pt_last_error()
                if state==2:break
                time.sleep(.001)
            assert state==2
            # Seeking after the producer has crossed into the following file must use the audible file.
            assert lib.pt_player_seek(player,.1)==1
            return np.concatenate(chunks)
        finally:lib.pt_player_destroy(player)
    split_output=playback(files[0],files[1]);joined_output=playback(files[2])
    assert np.array_equal(split_output,joined_output),np.max(np.abs(split_output-joined_output))
    # Random-access byte callbacks exercise the same interface used by HTTP/SMB streaming.
    eq.enabled=0
    stream_frames={}
    for file in [flac,mp3]:
        content=file.read_bytes()
        @READ
        def read(_,offset,buffer,count):
            data=content[offset:offset+count];C.memmove(buffer,data,len(data));return len(data)
        source=ByteSource(None,read,len(content));metadata=Info()
        assert lib.pt_source_info(source,file.suffix[1:].encode(),C.byref(metadata)),lib.pt_last_error()
        p=lib.pt_player_create_source(source,file.suffix[1:].encode(),fs,C.byref(eq));assert p,lib.pt_last_error()
        try:
            lib.pt_player_pause(p,0);total=0;deadline=time.time()+10
            while time.time()<deadline:
                buf=np.empty((512,2),np.float32);count=lib.pt_player_render(p,buf.ctypes.data,512);total+=count
                state=lib.pt_player_state(p);assert state!=-1
                if state==2:break
                time.sleep(.001)
            assert total==n,(file,total,n)
            stream_frames[file.suffix]=total
        finally:lib.pt_player_destroy(p)
    p=lib.pt_player_create(str(flac.resolve()).encode(),fs,C.byref(eq),0);assert p
    try:
        assert lib.pt_player_enqueue(p,str(flac.resolve()).encode())
        lib.pt_player_pause(p,0);total=0;changed=False;deadline=time.time()+10
        eq.enabled=1;eq.bands[0]=Band(0,1,1000,1,0)
        revision=lib.pt_player_set_eq_revision(p,C.byref(eq),0);assert revision>0
        while time.time()<deadline:
            buf=np.empty((512,2),np.float32);count=lib.pt_player_render(p,buf.ctypes.data,512);total+=count
            changed=changed or lib.pt_player_eq_revision(p)>=revision
            state=lib.pt_player_state(p);assert state!=-1
            if state==2:break
            time.sleep(.001)
        assert total==n*2,total
        assert lib.pt_player_track_index(p)==1 and changed
    finally:lib.pt_player_destroy(p)
    report={"status":"pass","flac_24bit_sample_identical":True,"mp3_gapless_frames":len(mp3_pcm),"src_frames":len(rendered),"analysis_true_peak":analysis.truePeak,"safety_db":analysis.safetyDB,"seek":True,"network_byte_source_frames":stream_frames,"gapless_frames":total,"audible_eq_revision":changed,"continuous_src_eq_sample_identical":True,"continuous_sequence_peak":continuous.truePeak,"independent_track_peaks":individual,"note":"Generated signals only; original music never committed."}
    Path(args.report).parent.mkdir(parents=True,exist_ok=True);Path(args.report).write_text(json.dumps(report,indent=2)+"\n");print(json.dumps(report,indent=2))
if __name__=='__main__':main()
