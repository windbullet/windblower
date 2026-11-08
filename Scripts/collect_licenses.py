"""Copy exact upstream license notices into the application, before XcodeGen."""
from pathlib import Path
import shutil
import urllib.request

root = Path(__file__).resolve().parents[1]
output = root / "App/Resources/Licenses"
output.mkdir(parents=True, exist_ok=True)
for source in (root / "Vendor/ios/licenses").glob("*"):
    shutil.copy2(source, output / source.name)
shutil.copy2(root / "THIRD_PARTY_NOTICES.md", output / "THIRD_PARTY_NOTICES.md")
sources = {
    "FlyingFox-MIT.txt": "https://raw.githubusercontent.com/swhitty/FlyingFox/0.27.1/LICENSE",
    "AMSMB2-LGPL.txt": "https://raw.githubusercontent.com/amosavian/AMSMB2/4.0.3/LICENSE",
    "Yams-MIT.txt": "https://raw.githubusercontent.com/jpsim/Yams/5.1.3/LICENSE",
    "libsmb2-COPYING.txt": "https://raw.githubusercontent.com/sahlberg/libsmb2/aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03/COPYING",
}
for name, url in sources.items():
    target = output / name
    if target.exists():
        continue
    alternatives = [url, url.replace("https://raw.githubusercontent.com/", "https://cdn.jsdelivr.net/gh/", 1)]
    # jsDelivr uses owner/repo@revision/path.
    parts = url.removeprefix("https://raw.githubusercontent.com/").split("/")
    alternatives[1] = "https://cdn.jsdelivr.net/gh/" + "/".join(parts[:2]) + "@" + parts[2] + "/" + "/".join(parts[3:])
    for candidate in alternatives:
        try:
            with urllib.request.urlopen(candidate, timeout=20) as response:
                target.write_bytes(response.read())
            break
        except Exception:
            if candidate == alternatives[-1]:
                raise
print("License notices bundled")
