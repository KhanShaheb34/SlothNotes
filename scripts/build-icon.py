#!/usr/bin/env python3
"""Package the generated Sloth artwork into standard PNG-backed ICNS sizes."""
from pathlib import Path
import struct
import subprocess

root = Path(__file__).resolve().parent.parent
work = root / '.build' / 'Sloth.iconset'
work.mkdir(parents=True, exist_ok=True)
chunks = []
for size, kind in [(16, b'icp4'), (32, b'icp5'), (64, b'icp6'), (128, b'ic07'),
                   (256, b'ic08'), (512, b'ic09'), (1024, b'ic10')]:
    output = work / f'{size}.png'
    subprocess.run(['/usr/bin/sips', '-z', str(size), str(size),
                    str(root / 'Resources' / 'Sloth.png'), '--out', str(output)],
                   check=True, stdout=subprocess.DEVNULL)
    data = output.read_bytes()
    chunks.append(kind + struct.pack('>I', len(data) + 8) + data)
payload = b''.join(chunks)
destination = root / 'Resources' / 'Sloth.icns'
destination.write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
print(destination)
