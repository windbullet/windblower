"""Test the compiled C++ kernel against independently designed RBJ/SciPy filters."""
import argparse
import ctypes as C
import json
import math
from pathlib import Path
import os
import numpy as np
from scipy import signal

class Band(C.Structure):
    _fields_ = [("type", C.c_int32), ("enabled", C.c_int32), ("frequency", C.c_double), ("q", C.c_double), ("gainDB", C.c_double)]
class EQ(C.Structure):
    _fields_ = [("enabled", C.c_int32), ("count", C.c_int32), ("preampDB", C.c_double), ("bands", Band * 32)]

def library(path):
    if os.name == "nt":
        os.add_dll_directory(str(Path(path).resolve().parent))
        if Path("C:/msys64/mingw64/bin").exists(): os.add_dll_directory("C:/msys64/mingw64/bin")
    lib = C.CDLL(str(Path(path).resolve()))
    lib.pt_dsp_create.argtypes = [C.c_double, C.c_int, C.POINTER(EQ)]; lib.pt_dsp_create.restype = C.c_void_p
    lib.pt_dsp_destroy.argtypes = [C.c_void_p]
    lib.pt_dsp_process.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p, C.c_size_t]; lib.pt_dsp_process.restype = C.c_int
    lib.pt_eq_response_db.argtypes = [C.POINTER(EQ), C.c_double, C.c_double]; lib.pt_eq_response_db.restype = C.c_double
    lib.pt_eq_l1_bound.argtypes = [C.POINTER(EQ), C.c_double]; lib.pt_eq_l1_bound.restype = C.c_double
    return lib

def rbj(kind, fs, frequency, q, gain):
    w = 2 * np.pi * frequency / fs; c, s = np.cos(w), np.sin(w)
    alpha = s / (2*q); a = 10**(gain / 40); r = 2*np.sqrt(a)*alpha
    if kind == 0: b, d = [1+alpha*a, -2*c, 1-alpha*a], [1+alpha/a, -2*c, 1-alpha/a]
    elif kind == 1:
        b = [a*((a+1)-(a-1)*c+r), 2*a*((a-1)-(a+1)*c), a*((a+1)-(a-1)*c-r)]
        d = [(a+1)+(a-1)*c+r, -2*((a-1)+(a+1)*c), (a+1)+(a-1)*c-r]
    elif kind == 2:
        b = [a*((a+1)+(a-1)*c+r), -2*a*((a-1)+(a+1)*c), a*((a+1)+(a-1)*c-r)]
        d = [(a+1)-(a-1)*c+r, 2*((a-1)-(a+1)*c), (a+1)-(a-1)*c-r]
    elif kind == 3: b, d = [(1-c)/2, 1-c, (1-c)/2], [1+alpha, -2*c, 1-alpha]
    elif kind == 4: b, d = [(1+c)/2, -(1+c), (1+c)/2], [1+alpha, -2*c, 1-alpha]
    elif kind == 5: b, d = [alpha, 0, -alpha], [1+alpha, -2*c, 1-alpha]
    else: b, d = [1, -2*c, 1], [1+alpha, -2*c, 1-alpha]
    return np.array(b)/d[0], np.array(d)/d[0]

def render(lib, eq, fs, data):
    data = np.ascontiguousarray(data, dtype=np.float64)
    out = np.empty_like(data); channels = 1 if data.ndim == 1 else data.shape[1]
    dsp = lib.pt_dsp_create(fs, channels, C.byref(eq)); assert dsp
    try:
        # Irregular blocks exercise state continuity, in-place safety is separately covered.
        for offset in range(0, len(data), 317):
            x, y = data[offset:offset+317], out[offset:offset+317]
            assert lib.pt_dsp_process(dsp, x.ctypes.data, y.ctypes.data, len(x))
    finally: lib.pt_dsp_destroy(dsp)
    assert np.isfinite(out).all()
    return out

def main():
    p=argparse.ArgumentParser();p.add_argument("--library",required=True);p.add_argument("--report",default="TestResults/dsp.json");args=p.parse_args()
    lib=library(args.library);rng=np.random.default_rng(5678)
    worst_db=0.;worst_null=0.;cases=0
    for fs in [44100.,48000.,96000.,192000.]:
        frequencies=np.geomspace(10,min(20000,fs*.49),91)
        for kind in range(7):
            for f,q,g in [(10,.1,-24),(20,30,24),(1000,.7071067811865476,6),(12000,5,-12),(20000,30,24)]:
                eq=EQ(1,1,0);eq.bands[0]=Band(kind,1,f,q,g)
                b,a=rbj(kind,fs,f,q,g);_,h=signal.freqz(b,a,worN=2*np.pi*frequencies/fs)
                measured=np.array([lib.pt_eq_response_db(C.byref(eq),fs,float(x)) for x in frequencies])
                valid=np.abs(h)>1e-5
                error=np.abs(measured[valid]-20*np.log10(np.abs(h[valid])))
                worst_db=max(worst_db,float(error.max(initial=0)))
                assert error.max(initial=0)<.01,(kind,fs,f,q,g,error.max())
                x=rng.uniform(-.01,.01,24000);y=render(lib,eq,fs,x);reference=signal.lfilter(b,a,x)
                worst_null=max(worst_null,float(np.max(np.abs(y-reference))))
                bound=lib.pt_eq_l1_bound(C.byref(eq),fs)
                impulse=np.zeros(60000);impulse[0]=1
                h_time=render(lib,eq,fs,impulse)
                assert np.sum(np.abs(h_time))<=bound*(1+1e-7),(kind,fs,f,q,bound)
                assert np.max(np.abs(y))<=bound*.01*(1+1e-7)
                cases+=1
    # Stereo state isolation, exact bypass and a 32-section unity chain.
    x=rng.uniform(-1,1,(12000,2));eq=EQ(0,1,0);eq.bands[0]=Band(0,1,1000,1,12)
    assert np.array_equal(x,render(lib,eq,48000,x))
    eq.enabled=1;eq.count=32
    for i in range(32):eq.bands[i]=Band(0,1,1000,1,0)
    assert np.array_equal(x,render(lib,eq,48000,x))
    # Coherent steady-state tone: residual excludes the intended linear response/phase.
    fs=48000; n=131072; frequency=1500
    eq=EQ(1,1,-12);eq.bands[0]=Band(0,1,1000,1,6)
    t=np.arange(n*2)/fs;x=.1*np.sin(2*np.pi*frequency*t);y=render(lib,eq,fs,x)[n:]
    wt=2*np.pi*frequency*np.arange(n)/fs
    basis=np.column_stack([np.sin(wt),np.cos(wt),np.ones(n)])
    fitted=basis@np.linalg.lstsq(basis,y,rcond=None)[0]
    residual=20*np.log10(max(np.sqrt(np.mean((y-fitted)**2)),1e-300))
    y32=y.astype(np.float32).astype(np.float64)
    residual32=20*np.log10(max(np.sqrt(np.mean((y32-basis@np.linalg.lstsq(basis,y32,rcond=None)[0])**2)),1e-300))
    assert residual < -160,residual
    assert residual32 < -140,residual32
    report={"status":"pass","compiled_kernel":str(Path(args.library).resolve()),"response_cases":cases,"maximum_response_error_db":worst_db,"maximum_sample_difference_vs_float64_direct_form":worst_null,"steady_state_residual_dbfs_float64":residual,"steady_state_residual_dbfs_float32":residual32,"bypass_sample_identical":True,"note":"Software PCM measurements; no analog DAC/headphone claim."}
    Path(args.report).parent.mkdir(parents=True,exist_ok=True);Path(args.report).write_text(json.dumps(report,indent=2)+"\n");print(json.dumps(report,indent=2))
if __name__=="__main__":main()
