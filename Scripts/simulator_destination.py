import json
import subprocess
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))["devices"]
for runtime, values in devices.items():
    if "iOS-26" in runtime:
        for device in values:
            if "iPad" in device["name"] and device.get("isAvailable"):
                print("platform=iOS Simulator,id=" + device["udid"])
                raise SystemExit(0)
raise SystemExit("No iPadOS 26 simulator installed. Install an iOS 26 runtime in Xcode.")
