from pathlib import Path
import math
import re
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image, ImageCms, ImageDraw


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "app-icon-512.svg"
OUTPUT = ROOT / "app-icon-512.png"
SCALE = 4


def sampled_subpaths(path_data: str):
    tokens = re.findall(r"[A-Za-z]|-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?", path_data)
    paths, points = [], []
    command = None
    index = 0
    x = y = start_x = start_y = 0.0

    def number():
        nonlocal index
        value = float(tokens[index])
        index += 1
        return value

    while index < len(tokens):
        if tokens[index].isalpha():
            command = tokens[index]
            index += 1
        if command == "M":
            if points:
                paths.append(points)
            x, y = number(), number()
            start_x, start_y = x, y
            points = [(x, y)]
            command = "L"
        elif command == "L":
            x, y = number(), number()
            points.append((x, y))
        elif command == "H":
            x = number()
            points.append((x, y))
        elif command == "V":
            y = number()
            points.append((x, y))
        elif command == "C":
            x1, y1, x2, y2, x3, y3 = (number() for _ in range(6))
            x0, y0 = x, y
            for step in range(1, 33):
                t = step / 32
                u = 1 - t
                points.append((
                    u**3 * x0 + 3 * u**2 * t * x1 + 3 * u * t**2 * x2 + t**3 * x3,
                    u**3 * y0 + 3 * u**2 * t * y1 + 3 * u * t**2 * y2 + t**3 * y3,
                ))
            x, y = x3, y3
        elif command in {"Z", "z"}:
            points.append((start_x, start_y))
            paths.append(points)
            points = []
            command = None
        else:
            raise ValueError(f"Unsupported SVG path command: {command}")
    if points:
        paths.append(points)
    return paths


tree = ET.parse(SOURCE)
path = tree.find("{http://www.w3.org/2000/svg}path")
subpaths = sampled_subpaths(path.attrib["d"])

size = 512 * SCALE
yy, xx = np.indices((size, size), dtype=np.float32)
xx /= SCALE
yy /= SCALE
start = np.array([64.0, 32.0])
direction = np.array([384.0, 448.0])
t = np.clip(((xx - start[0]) * direction[0] + (yy - start[1]) * direction[1]) / np.dot(direction, direction), 0, 1)
start_color = np.array([0x16, 0x77, 0xFF], dtype=np.float32)
end_color = np.array([0x03, 0x31, 0x8B], dtype=np.float32)
rgb = (start_color + t[..., None] * (end_color - start_color)).astype(np.uint8)
background = Image.fromarray(rgb, "RGB")

mask = Image.new("L", (size, size), 0)
draw = ImageDraw.Draw(mask)
for index, subpath in enumerate(subpaths):
    transformed = [((65.72 + x * .9784) * SCALE, (66 + y * .9784) * SCALE) for x, y in subpath]
    draw.polygon(transformed, fill=255 if index == 0 else 0)

foreground = Image.new("RGB", (size, size), "#F6F8FF")
result = Image.composite(foreground, background, mask)
result = result.resize((512, 512), Image.Resampling.LANCZOS).convert("RGBA")
profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
result.save(OUTPUT, format="PNG", optimize=True, icc_profile=profile)
