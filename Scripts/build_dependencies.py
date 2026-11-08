#!/usr/bin/env python3
"""Pinned, source-built FLAC/mpg123/soxr. No signing credentials required.

python Scripts/build_dependencies.py --platform ios|simulator|host
Writes only Vendor/ and .build/. Run on macOS for Apple SDK targets.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PINS = {
    "flac": ("xiph/flac", "1.5.0", "."),
    "mpg123": ("madebr/mpg123", "37627c0eb90bfa1111820391f5749848ecc45d61", "ports/cmake"),
    "soxr": ("chirlu/soxr", "945b592b70470e29f917f4de89b4281fbbd540c0", "."),
}

def run(args, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kwargs)

def source(name):
    repo, revision, _ = PINS[name]
    dest = ROOT / "Vendor" / "sources" / name
    marker = dest / ".puretone-revision"
    if marker.exists() and marker.read_text().strip() == revision:
        return dest
    archive = ROOT / ".build" / "downloads" / f"{name}-{revision}.tar.gz"
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        url = f"https://codeload.github.com/{repo}/tar.gz/{revision}"
        for attempt in range(4):
            try:
                request = urllib.request.Request(url, headers={"User-Agent": "PureTone-source-build/0.1"})
                with urllib.request.urlopen(request, timeout=45) as response:
                    temporary = archive.with_suffix(".partial")
                    with temporary.open("wb") as output:
                        shutil.copyfileobj(response, output)
                    temporary.replace(archive)
                break
            except Exception:
                if attempt == 3:
                    raise
                time.sleep(2 ** attempt)
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as tar:
        for item in tar.getmembers():
            stripped = Path(*Path(item.name).parts[1:])
            if not stripped.parts:
                continue
            if item.issym() or item.islnk() or ".." in stripped.parts or stripped.is_absolute():
                continue
            item.name = str(stripped)
            tar.extract(item, dest, filter="data")
    marker.write_text(revision)
    return dest

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=["ios", "simulator", "host"], default="host")
    options = parser.parse_args()
    output = ROOT / "Vendor" / options.platform
    common = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DBUILD_SHARED_LIBS=OFF",
              f"-DCMAKE_INSTALL_PREFIX={output}", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"]
    if options.platform != "host":
        if platform.system() != "Darwin":
            raise SystemExit("Apple targets require macOS + Xcode (use the included GitHub Actions workflow).")
        sdk = "iphoneos" if options.platform == "ios" else "iphonesimulator"
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        common += ["-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={sdk_path}", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                   "-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0", "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"]
    elif platform.system() == "Windows":
        # Ninja avoids depending on a full Visual Studio installation.
        ninja = shutil.which("ninja")
        gcc = shutil.which("gcc")
        if not ninja or not gcc:
            raise SystemExit("Put Ninja and your C/C++ compiler on PATH before building host codecs.")
        common += ["-G", "Ninja", f"-DCMAKE_C_COMPILER={gcc}", f"-DCMAKE_CXX_COMPILER={shutil.which('g++')}"]
    extras = {
        "flac": ["-DBUILD_CXXLIBS=OFF", "-DBUILD_PROGRAMS=OFF", "-DBUILD_EXAMPLES=OFF", "-DBUILD_TESTING=OFF",
                 "-DBUILD_DOCS=OFF", "-DINSTALL_MANPAGES=OFF", "-DWITH_OGG=OFF", "-DWITH_STACK_PROTECTOR=OFF"],
        "mpg123": ["-DBUILD_LIBOUT123=OFF", "-DBUILD_PROGRAMS=OFF", "-DBUILD_TESTING=OFF", "-DGAPLESS=ON",
                   "-DNO_EQUALIZER=ON", "-DNO_DOWNSAMPLE=ON", "-DNO_NTOM=ON", "-DNETWORK=OFF"],
        "soxr": ["-DBUILD_TESTS=OFF", "-DBUILD_EXAMPLES=OFF", "-DWITH_OPENMP=OFF", "-DWITH_LSR_BINDINGS=OFF"],
    }
    if options.platform != "host":
        # The SDK link probe finds strerror_l, but iOS's public headers do not declare it.
        # Use mpg123's portable strerror fallback; the decoder arithmetic is unaffected.
        extras["mpg123"].append("-DHAVE_STRERROR_L=OFF")
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        sources = dict(zip(PINS, executor.map(source, PINS)))
    for name, src in sources.items():
        build = ROOT / ".build" / f"{name}-{options.platform}"
        run(["cmake", "-S", src / PINS[name][2], "-B", build, *common, *extras[name]])
        run(["cmake", "--build", build, "--config", "Release", "--parallel", "4"])
        run(["cmake", "--install", build, "--config", "Release"])
    notices = output / "licenses"
    notices.mkdir(parents=True, exist_ok=True)
    for name, src in sources.items():
        for candidate in src.iterdir():
            if candidate.is_file() and candidate.name.lower().startswith(("copying", "license")):
                shutil.copy2(candidate, notices / f"{name}-{candidate.name}")
    manifest = {name: {"repository": repo, "revision": rev} for name, (repo, rev, _) in PINS.items()}
    (output / "sources.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Dependencies ready: {output}")

if __name__ == "__main__":
    main()
