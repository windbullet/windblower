"""Capture the actual launched SwiftUI application after successful simulator tests."""
from pathlib import Path
import subprocess
import sys
import time

destination = sys.argv[1]
device = destination.rsplit("id=", 1)[-1]
output = Path("TestResults/library-ipad.png")
subprocess.run(["xcrun", "simctl", "launch", device, "com.puretone.player"], check=True)
time.sleep(3)
subprocess.run(["xcrun", "simctl", "io", device, "screenshot", str(output)], check=True)
