"""Export selected XCTest UI attachments, without creating or modifying screenshots."""
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
bundle = root / 'TestResults/PureTone.xcresult'
export = root / 'TestResults/ui-attachments'
export.mkdir(parents=True, exist_ok=True)
process = subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(bundle), '--output-path', str(export)], capture_output=True, text=True, timeout=60)
print(process.stdout + process.stderr)
process.check_returncode()
names = {'Read-only logarithmic EQ': 'eq-ipad.png', 'Playlist with library picker': 'playlist-picker-ipad.png'}

def inspect(value):
    if isinstance(value, dict):
        strings = [item for item in value.values() if isinstance(item, str)]
        for label, output in names.items():
            if not any(label in item for item in strings): continue
            for filename in strings:
                source = export / filename
                if filename.lower().endswith('.png') and source.is_file():
                    shutil.copy2(source, root / 'TestResults' / output)
                    print('Exported', output)
        for item in value.values(): inspect(item)
    elif isinstance(value, list):
        for item in value: inspect(item)

for manifest in export.glob('*.json'):
    inspect(json.loads(manifest.read_text(encoding='utf-8')))
