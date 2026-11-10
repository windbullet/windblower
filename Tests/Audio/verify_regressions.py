"""User regressions: continuous-state A/B, no gain dip, shared headroom, real faults."""
import argparse
import ctypes as C
import json
from pathlib import Path
import subprocess
import time

import numpy as np
from verify_dsp import library, EQ, Band, render
from verify_codecs import Analysis, ByteSource, READ


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', required=True)
    parser.add_argument('--report', default='TestResults/regressions.json')
    args = parser.parse_args()
    lib = library(args.library)
    signatures = {
        'pt_player_create': ([C.c_char_p, C.c_double, C.POINTER(EQ), C.c_double], C.c_void_p),
        'pt_player_create_source': ([ByteSource, C.c_char_p, C.c_double, C.POINTER(EQ)], C.c_void_p),
        'pt_player_destroy': ([C.c_void_p], None),
        'pt_player_pause': ([C.c_void_p, C.c_int], None),
        'pt_player_render': ([C.c_void_p, C.c_void_p, C.c_size_t], C.c_size_t),
        'pt_player_state': ([C.c_void_p], C.c_int),
        'pt_player_set_bypass': ([C.c_void_p, C.c_int, C.c_int], C.c_uint64),
        'pt_player_bypass_revision': ([C.c_void_p], C.c_uint64),
        'pt_player_eq_revision': ([C.c_void_p], C.c_uint64),
        'pt_player_error': ([C.c_void_p], C.c_char_p),
        'pt_player_set_verified_eq_revision': ([C.c_void_p, C.POINTER(EQ), C.c_double], C.c_uint64),
        'pt_analyze_comparison_sequence_cancelable': ([C.POINTER(C.c_char_p), C.c_size_t, C.c_double,
            C.POINTER(EQ), C.POINTER(Analysis), C.c_void_p, C.c_void_p], C.c_int),
        'pt_last_error': ([], C.c_char_p),
    }
    for name, (arguments, result) in signatures.items():
        fn = getattr(lib, name); fn.argtypes = arguments; fn.restype = result
    fs = 48000
    count = fs * 20
    t = np.arange(count)/fs
    samples = np.column_stack([.25*np.sin(2*np.pi*997*t)+.03*np.sin(2*np.pi*10*t),
                               .21*np.sin(2*np.pi*1301*t)])
    pcm = np.round(samples*2**23).astype('<i4')
    original = pcm.astype(np.float64)/2**23
    root = Path('.build/fixtures'); root.mkdir(parents=True, exist_ok=True)
    raw = root/'regression-long.s32'; raw.write_bytes((pcm << 8).tobytes())
    file = root/'regression-long.flac'
    subprocess.run(['ffmpeg', '-y', '-f', 's32le', '-ar', str(fs), '-ac', '2', '-i', str(raw),
                    '-c:a', 'flac', str(file)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def create(eq, gain=None):
        p = lib.pt_player_create(str(file.resolve()).encode(), fs, C.byref(eq), eq.preampDB if gain is None else gain)
        assert p, lib.pt_last_error()
        lib.pt_player_pause(p, 0)
        return p

    def collect(p, wanted):
        chunks = []; total = 0; deadline = time.monotonic()+10
        while total < wanted and time.monotonic() < deadline:
            data = np.empty((min(311, wanted-total), 2), np.float32)
            n = lib.pt_player_render(p, data.ctypes.data, len(data))
            if n: chunks.append(data[:n].copy()); total += n
            assert lib.pt_player_state(p) != -1, lib.pt_player_error(p)
            if lib.pt_player_state(p) == 2: break
            time.sleep(.0001)
        assert total == wanted, (total, wanted)
        return np.concatenate(chunks)

    # Flat EQ with ten unity bands: every sample remains identical through repeated toggles.
    flat = EQ(1, 10, -12)
    for i in range(10): flat.bands[i] = Band(0, 1, 31*2**i, .7071, 0)
    expected = (original*10**(-12/20)).astype(np.float32)
    p = create(flat)
    toggle_frames = []
    try:
        offset = 0
        for bypassed in [0, 1]*5:
            revision = lib.pt_player_set_bypass(p, bypassed, 1)
            output = collect(p, fs//3)
            assert np.array_equal(output, expected[offset:offset+len(output)])
            assert lib.pt_player_bypass_revision(p) >= revision
            assert lib.pt_player_eq_revision(p) == 0, 'Power toggle must not submit a filter reconstruction'
            toggle_frames.append(len(output)); offset += len(output)
    finally: lib.pt_player_destroy(p)

    # A long-lived high-Q state must stay warm while auditioning dry; returning wet is exact.
    resonant = EQ(1, 1, -35)
    resonant.bands[0] = Band(0, 1, 10, 30, 24)
    expected_wet = render(lib, resonant, fs, original).astype(np.float32)
    expected_dry = (original*10**(-35/20)).astype(np.float32)
    p = create(resonant)
    try:
        offset = len(collect(p, fs*3))
        for bypassed, preserve in [(1, 1), (0, 1), (1, 0), (0, 1), (1, 1), (0, 1)]:
            revision = lib.pt_player_set_bypass(p, bypassed, preserve)
            # Drain the fixed ring and crossfade; this is a PCM duration, not wall-clock sleep.
            offset += len(collect(p, fs//3))
            assert lib.pt_player_bypass_revision(p) >= revision
            output = collect(p, fs//5)
            reference = expected_wet if not bypassed else (expected_dry if preserve else original.astype(np.float32))
            assert np.array_equal(output, reference[offset:offset+len(output)])
            offset += len(output)
    finally: lib.pt_player_destroy(p)

    # A strongly cutting filter with positive preamp can be safe wet and clip the matched dry.
    # Analyze both paths, then verify that either one stays below the same static ceiling.
    cut = EQ(1, 1, 24); cut.bands[0] = Band(3, 1, 40, .7071, 0)
    paths = (C.c_char_p*1)(str(file.resolve()).encode())
    report = Analysis()
    assert lib.pt_analyze_comparison_sequence_cancelable(paths, 1, fs, C.byref(cut), C.byref(report), None, None)
    assert report.safetyDB < -10, report.safetyDB
    p = create(cut, report.effectivePreampDB)
    peaks = []
    try:
        for bypassed in [0, 1, 0, 1]:
            lib.pt_player_set_bypass(p, bypassed, 1)
            output = collect(p, fs//2)
            peaks.append(float(np.max(np.abs(output))))
        assert max(peaks) <= 10**(-1/20)+1e-6, peaks
    finally: lib.pt_player_destroy(p)

    # Repeated verified parameter edits keep the old signal until a safe replacement is ready.
    p = create(flat)
    try:
        collect(p, fs)
        for index in range(6):
            setting = EQ(1, 1, -30)
            setting.bands[0] = Band(index % 3, 1, [10, 200, 1000, 8000, 18000, 20][index], 30, 24 if index % 2 else -24)
            result = Analysis()
            assert lib.pt_analyze_comparison_sequence_cancelable(paths, 1, fs, C.byref(setting), C.byref(result), None, None)
            revision = lib.pt_player_set_verified_eq_revision(p, C.byref(setting), result.effectivePreampDB)
            collect(p, fs)
            assert lib.pt_player_eq_revision(p) >= revision
    finally: lib.pt_player_destroy(p)

    # Fault text belongs to the player, not thread-local state on the worker or a generic alert.
    overloaded = EQ(1, 1, 24); overloaded.bands[0] = Band(0, 1, 1000, 1, 0)
    p = create(overloaded)
    try:
        deadline = time.monotonic()+5
        while lib.pt_player_state(p) != -1 and time.monotonic() < deadline: time.sleep(.001)
        detail = lib.pt_player_error(p).decode()
        assert detail.startswith('PCM overload:') and 'dBFS' in detail and 'frame=' in detail, detail
    finally: lib.pt_player_destroy(p)
    raw_bytes = file.read_bytes()
    @READ
    def read(_, offset, buffer, size):
        chunk = raw_bytes[offset:offset+size]; C.memmove(buffer, chunk, len(chunk)); return len(chunk)
    bypass = EQ(0, 1, 0); bypass.bands[0] = Band(0, 1, 1000, 1, 0)
    p = lib.pt_player_create_source(ByteSource(None, read, len(raw_bytes)), b'flac', fs, C.byref(bypass)); assert p
    try:
        lib.pt_player_set_verified_eq_revision(p, C.byref(flat), -12)
        deadline = time.monotonic()+5
        while lib.pt_player_state(p) != -1 and time.monotonic() < deadline: time.sleep(.001)
        non_overload = lib.pt_player_error(p).decode()
        assert 'complete local originals' in non_overload and not non_overload.startswith('PCM overload:'), non_overload
    finally: lib.pt_player_destroy(p)

    result = {'status': 'pass', 'flat_ab_all_samples_identical': True, 'power_does_not_reconstruct_filters': True,
              'high_q_wet_state_survives_bypass': True, 'pure_bypass_restores_unit_gain': True,
              'comparison_safety_db': report.safetyDB, 'comparison_output_peaks': peaks,
              'verified_parameter_changes_without_overload': 6,
              'overload_has_actual_peak_and_frame': True, 'non_overload_fault_is_distinct': True}
    Path(args.report).parent.mkdir(parents=True, exist_ok=True)
    Path(args.report).write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
