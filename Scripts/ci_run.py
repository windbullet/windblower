"""Stream a build command and expose its diagnostics in public Actions annotations."""
import argparse
from pathlib import Path
import re
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--log", required=True)
parser.add_argument("command", nargs=argparse.REMAINDER)
options = parser.parse_args()
command = options.command
if command[:1] == ["--"]:
    command = command[1:]
path = Path(options.log)
path.parent.mkdir(parents=True, exist_ok=True)
lines = []
with path.open("w", encoding="utf-8") as output:
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", bufsize=1)
    for line in process.stdout:
        print(line, end="", flush=True)
        output.write(line)
        lines.append(line.rstrip())
code = process.wait()
if code:
    diagnostics = [line for line in lines if re.search(r"\berror:|CMake Error|FAILED:|fatal error:|AssertionError|Traceback|BUILD FAILED|TEST FAILED", line, re.IGNORECASE)]
    if not diagnostics:
        diagnostics = lines[-25:]
    for line in diagnostics[:40]:
        message = line.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error::" + message)
sys.exit(code)
