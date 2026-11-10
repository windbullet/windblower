import argparse
import json
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--boot", action="store_true", help="Wait for the selected device to finish its first boot")
options = parser.parse_args()
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))["devices"]
for runtime, values in devices.items():
    if "iOS-26" in runtime:
        for device in values:
            if "iPad" in device["name"] and device.get("isAvailable"):
                if options.boot:
                    if device["state"] == "Shutdown":
                        subprocess.run(["xcrun", "simctl", "boot", device["udid"]], check=True, timeout=45, stdout=sys.stderr)
                    subprocess.run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"], check=True, timeout=180, stdout=sys.stderr)
                print("platform=iOS Simulator,id=" + device["udid"])
                raise SystemExit(0)
raise SystemExit("No iPadOS 26 simulator installed. Install an iOS 26 runtime in Xcode.")
