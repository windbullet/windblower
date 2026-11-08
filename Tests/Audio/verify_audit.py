"""Regression checks for the EQ/signal-path audit: full history, stereo, IMD, bypass."""
import argparse
import ctypes as C
import json
from pathlib import Path
import subprocess
import time
import numpy as np
from scipy import signal
from verify_dsp import library, EQ, Band, rbj, render


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--report", default="TestResults/audit.json")
    args = parser.parse_args()
    lib = library(args.library)
    lib.pt_player_create.argtypes = [C.c_char_p, C.c_double, C.POINTER(EQ), C.c_double]
    lib.pt_player_create.restype = C.c_void_p
    lib.pt_player_pause.argtypes = [C.c_void_p, C.c_int]
    lib.pt_player_destroy.argtypes = [C.c_void_p]
    lib.pt_player_render.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t]
    lib.pt_player_render.restype = C.c_size_t
    lib.pt_player_state.argtypes = [C.c_void_p]
    lib.pt_player_state.restype = C.c_int
    lib.pt_player_seek.argtypes = [C.c_void_p, C.c_double]
    lib.pt_player_seek.restype = C.c_int
    lib.pt_player_enqueue.argtypes = [C.c_void_p, C.c_char_p]
    lib.pt_player_enqueue.restype = C.c_int
    lib.pt_player_track_index.argtypes = [C.c_void_p]
    lib.pt_player_track_index.restype = C.c_uint64
    for name in ["pt_player_set_eq_revision", "pt_player_set_verified_eq_revision"]:
        f = getattr(lib, name)
        f.argtypes = [C.c_void_p, C.POINTER(EQ), C.c_double]
        f.restype = C.c_uint64
    lib.pt_player_eq_revision.argtypes = [C.c_void_p]
    lib.pt_player_eq_revision.restype = C.c_uint64
    lib.pt_last_error.restype = C.c_char_p

    fs = 48000
    length = fs * 7
    rng = np.random.default_rng(109)
    pcm = rng.integers(-2**20, 2**20, (length, 2), dtype=np.int32)
    pcm[:fs] += (np.sin(2*np.pi*10*np.arange(fs)/fs)*2**21).astype(np.int32)[:, None]
    source = pcm.astype(np.float64) / 2**23
    root = Path(".build/fixtures")
    root.mkdir(parents=True, exist_ok=True)
    raw = root / "audit.s32"
    raw.write_bytes((pcm << 8).astype('<i4').tobytes())
    file = root / "audit.flac"
    subprocess.run(["ffmpeg", "-y", "-f", "s32le", "-ar", str(fs), "-ac", "2", "-i", str(raw), "-c:a", "flac", str(file)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    eq = EQ(1, 1, -35)
    eq.bands[0] = Band(0, 1, 10, 30, 24)
    expected = render(lib, eq, fs, source).astype(np.float32)
    def create(config, rate=fs):
        p = lib.pt_player_create(str(file.resolve()).encode(), rate, C.byref(config), config.preampDB)
        assert p, lib.pt_last_error()
        return p
    def collect(player, limit=10000000):
        chunks = []
        total = 0
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and total < limit:
            buf = np.empty((min(347, limit-total), 2), dtype=np.float32)
            n = lib.pt_player_render(player, buf.ctypes.data, len(buf))
            if n:
                chunks.append(buf[:n].copy())
                total += n
            state = lib.pt_player_state(player)
            assert state != -1, lib.pt_last_error()
            if state == 2:
                break
            time.sleep(.0005)
        return np.concatenate(chunks) if chunks else np.empty((0, 2), np.float32)

    # Baseline end-to-end Float32 transparency, not just an isolated double DSP copy.
    bypass = EQ(0, 1, 0)
    bypass.bands[0] = Band(0, 1, 1000, 1, 0)
    p = create(bypass)
    try:
        lib.pt_player_pause(p, 0)
        assert np.array_equal(collect(p), source.astype(np.float32))
    finally:
        lib.pt_player_destroy(p)

    # A high-Q low-frequency section needs much more than two seconds of input history.
    for rate in [fs, 44100]:
        p = create(eq, rate)
        try:
            lib.pt_player_pause(p, 0)
            full = collect(p)
            seconds = 3.125
            assert lib.pt_player_seek(p, seconds) == 1, lib.pt_last_error()
            actual = collect(p)
            reference = full[int(np.floor(seconds*rate + .5)):]
            assert np.array_equal(actual, reference), (rate, np.max(np.abs(actual-reference)))
        finally:
            lib.pt_player_destroy(p)

    # Seeking in a later continuous track preserves the prior track's DSP/SRC history.
    p = create(eq, 44100)
    try:
        assert lib.pt_player_enqueue(p, str(file.resolve()).encode())
        lib.pt_player_pause(p, 0)
        full = collect(p)
        assert lib.pt_player_track_index(p) == 1
        assert len(full) == length*2*44100//fs
        seconds = 2.125
        assert lib.pt_player_seek(p, seconds) == 1, lib.pt_last_error()
        actual = collect(p)
        offset = int(np.floor((length/fs+seconds)*44100+.5))
        assert np.array_equal(actual, full[offset:])
    finally:
        lib.pt_player_destroy(p)

    # Same-shape gain transitions must rescale existing states instead of resetting them.
    p = create(eq)
    try:
        lib.pt_player_pause(p, 0)
        prefix = collect(p, fs*3)
        revision = lib.pt_player_set_eq_revision(p, C.byref(eq), -41)
        output = collect(p)
        expected_quiet = expected[len(prefix):].astype(np.float64) * 10**(-6/20)
        assert lib.pt_player_eq_revision(p) >= revision
        assert np.max(np.abs(output[fs:]-expected_quiet[fs:])) < 1e-8
    finally:
        lib.pt_player_destroy(p)

    # A verified filter switch must reconstruct the original full-track state before fade-in.
    p = create(bypass)
    try:
        lib.pt_player_pause(p, 0)
        prefix = collect(p, fs*3)
        revision = lib.pt_player_set_verified_eq_revision(p, C.byref(eq), -35)
        output = collect(p)
        assert lib.pt_player_eq_revision(p) >= revision
        assert np.array_equal(output[fs:], expected[len(prefix)+fs:])
    finally:
        lib.pt_player_destroy(p)

    # Channel isolation with a nontrivial filter and an active 32-band cascade.
    stereo = np.zeros((fs*2, 2));stereo[0, 0] = .1
    response = render(lib, eq, fs, stereo)
    assert np.array_equal(response[:, 1], np.zeros(len(response)))
    cascade = EQ(1, 32, -40)
    for i in range(32):
        cascade.bands[i] = Band(i % 3, 1, float(np.geomspace(20, 19000, 32)[i]), .7 + i/16, 3 if i % 2 else -3)
    noise = rng.uniform(-.02, .02, (fs*2, 2))
    actual = render(lib, cascade, fs, noise)
    reference = noise * 10**(-40/20)
    for band in cascade.bands:
        b, a = rbj(band.type, fs, band.frequency, band.q, band.gainDB)
        reference = signal.lfilter(b, a, reference, axis=0)
    cascade_error = float(np.max(np.abs(actual-reference)))
    assert cascade_error < 1e-10
    assert np.sqrt(np.mean(reference**2)) > 1e-5, "Cascade must retain a meaningful signal level"

    # 32 resonant shelves can need >1000 dB of conservative attenuation during editing.
    # Internal safety gain is deliberately wider than the user's -60...+24 dB control.
    extreme = EQ(1, 32, -24)
    for i in range(32):
        extreme.bands[i] = Band(2, 1, 10, 30, 24)
    extreme_bound = lib.pt_eq_l1_bound(C.byref(extreme), fs)
    extreme.preampDB += min(0., -13-20*np.log10(extreme_bound))
    extreme_output = render(lib, extreme, fs, noise)
    assert np.isfinite(extreme_output).all() and np.max(np.abs(extreme_output)) < 1

    # Low sample rates and the applied Nyquist clamp, with a separate absolute notch criterion.
    boundary_cases = 0
    boundary_error = 0.
    notch_zero = 0.
    for rate in [8000, 16000, 22050, 32000, 44100, 48000, 96000, 192000]:
        for kind in range(7):
            for centre, q, gain in [(10, .1, -24), (10, 30, 24), (min(20000, .498*rate), 30, 24)]:
                setting = EQ(1, 1, 0)
                setting.bands[0] = Band(kind, 1, centre, q, gain)
                frequencies = np.unique(np.r_[np.geomspace(10, min(20000, .498*rate), 81), centre])
                b, a = rbj(kind, rate, centre, q, gain)
                _, h = signal.freqz(b, a, worN=2*np.pi*frequencies/rate)
                measured = np.array([lib.pt_eq_response_db(C.byref(setting), rate, float(f)) for f in frequencies])
                assert not np.isnan(measured).any()
                valid = np.abs(h) > 1e-5
                error = float(np.max(np.abs(measured[valid] - 20*np.log10(np.abs(h[valid])))))
                assert error < .01, (kind, rate, centre, q, error)
                boundary_error = max(boundary_error, error)
                if kind == 6:
                    zero = 10**(lib.pt_eq_response_db(C.byref(setting), rate, centre)/20)
                    notch_zero = max(notch_zero, zero)
                    assert zero < 1e-7, (rate, centre, q, zero)
                boundary_cases += 1

    # Coherent 2-tone+multitone residual excludes only the intended tones and DC.
    size = 131072
    bins = [79, 430, 14001, 14273]
    phases = np.arange(size*2)
    multitone = sum(.025*np.sin(2*np.pi*k*phases/size) for k in bins)
    test = EQ(1, 3, -8)
    test.bands[0] = Band(1, 1, 80, .7071, 5)
    test.bands[1] = Band(0, 1, 1000, 2, -4)
    test.bands[2] = Band(2, 1, 10000, .7071, 3)
    output = render(lib, test, fs, multitone)[size:]
    residuals = []
    for samples in [output, output.astype(np.float32).astype(np.float64)]:
        spectrum = np.fft.rfft(samples)
        spectrum[[0, *bins]] = 0
        null = np.fft.irfft(spectrum, n=size)
        residuals.append(float(20*np.log10(max(1e-300, np.sqrt(np.mean(null**2))))))
    assert residuals[0] < -160 and residuals[1] < -140, residuals

    report = {"status": "pass", "full_player_bypass_sample_identical": True,
              "seek_equals_continuous_native_and_src": True, "verified_switch_full_history_sample_identical": True,
              "seek_later_track_preserves_continuous_history": True,
              "gain_only_preserves_history": True, "stereo_no_crossfeed": True,
              "nonunity_32_band_max_sample_error": cascade_error,
              "extreme_32_shelf_safe_gain_db": extreme.preampDB,
              "boundary_response_cases": boundary_cases, "boundary_max_response_error_db": boundary_error,
              "notch_centre_max_absolute_amplitude": notch_zero,
              "multitone_residual_dbfs_float64": residuals[0], "multitone_residual_dbfs_float32": residuals[1],
              "note": "Generated digital fixtures; fixed-parameter results are not a bound on all settings, transients or analog hardware."}
    Path(args.report).parent.mkdir(parents=True, exist_ok=True)
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
