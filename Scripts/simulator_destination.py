import argparse
import json
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--boot", action="store_true", help="Wait for the selected device to finish its first boot")
options = parser.parse_args()
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], text=True, timeout=45))["devices"]
candidates = []
for runtime, values in devices.items():
    if "iOS-26" in runtime:
        for device in values:
            if "iPad" in device["name"] and device.get("isAvailable"):
                candidates.append(device)
if not candidates:
    raise SystemExit("No iPadOS 26 simulator installed. Install an iOS 26 runtime in Xcode.")

# Reuse a running device; on a fresh runner prefer the closest available mini model.
candidates.sort(key=lambda device: (device["state"] != "Booted", "mini" not in device["name"].lower()))
device = candidates[0]
if options.boot:
    log = Path("TestResults/simulator-boot.log")
    log.parent.mkdir(parents=True, exist_ok=True)
    def run(arguments, timeout, check=True):
        command = ["xcrun", "simctl", *arguments]
        with log.open("a", encoding="utf-8") as output:
            output.write("$ " + " ".join(command) + "\n"); output.flush()
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
                message = result.stdout + result.stderr
                output.write(message); output.flush()
                print(message, end="", file=sys.stderr, flush=True)
                if check:
                    result.check_returncode()
            except subprocess.TimeoutExpired as error:
                message = error.stdout or ""
                if isinstance(message, bytes):
                    message = message.decode("utf-8", errors="replace")
                output.write(message + f"\nerror: simulator command timed out after {timeout}s\n")
                raise
    for attempt, timeout in enumerate([240, 180]):
        try:
            if attempt or device["state"] == "Shutdown":
                run(["boot", device["udid"]], timeout=45)
            run(["bootstatus", device["udid"], "-b"], timeout=timeout)
            break
        except (subprocess.SubprocessError, OSError):
            if attempt:
                raise
            # Restart only this fresh job's simulator; no host files or unrelated devices change.
            run(["shutdown", device["udid"]], timeout=60, check=False)
print("platform=iOS Simulator,id=" + device["udid"])
