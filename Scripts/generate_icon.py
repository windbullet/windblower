"""Generate the bundled, code-drawn PureTone icon (Pillow)."""
import json
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1] / "App/Assets.xcassets"
icon = root / "AppIcon.appiconset"
icon.mkdir(parents=True, exist_ok=True)
size = 1024
image = Image.new("RGB", (size, size))
pixels = image.load()
for y in range(size):
    for x in range(size):
        position = (x + y) / (2 * size)
        pixels[x, y] = tuple(round(a + (b - a) * position) for a, b in zip((28, 91, 74), (55, 153, 118)))
draw = ImageDraw.Draw(image)
draw.ellipse((190, 190, 834, 834), outline=(220, 239, 226), width=8)
for x, height in [(328, 94), (420, 220), (512, 366), (604, 220), (696, 94)]:
    draw.rounded_rectangle((x - 23, 512 - height / 2, x + 23, 512 + height / 2), radius=23, fill=(244, 247, 233))
image.save(icon / "AppIcon.png", optimize=True)
(icon / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
(root / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n')
