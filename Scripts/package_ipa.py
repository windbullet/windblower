"""Package an existing unsigned .app; never requests or stores Apple credentials."""
import hashlib
import os
from pathlib import Path
import sys
import zipfile
app = Path(sys.argv[1]).resolve()
if not app.is_dir() or app.suffix != ".app":
    raise SystemExit("Pass the built .app directory")
output = Path(__file__).resolve().parents[1] / "build"
output.mkdir(exist_ok=True)
ipa = output / "PureTone-unsigned.ipa"
with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob("*")):
        name = "Payload/" + app.name + "/" + path.relative_to(app).as_posix()
        if path.is_symlink():
            item = zipfile.ZipInfo(name); item.create_system = 3; item.external_attr = 0o120777 << 16
            archive.writestr(item, os.readlink(path))
        elif path.is_file():
            archive.write(path, name)
digest = hashlib.file_digest(ipa.open("rb"), "sha256").hexdigest()
(output / "SHA256SUMS.txt").write_text(digest + "  " + ipa.name + "\n")
print(ipa)
