# Sloth icon

Sloth's icon is original artwork generated for this app. It is a white, smiling sloth hanging from a branch on a rounded coral-red tile, with soft depth and a transparent area outside the tile.

The source artwork is [Resources/Sloth.png](../Resources/Sloth.png). This description records the design brief rather than a verbatim generation prompt.

![Sloth app icon](../Resources/Sloth.png)

## Packaging

Run this after intentionally changing the source artwork:

```sh
python3 scripts/build-icon.py
./scripts/build.sh
```

[scripts/build-icon.py](../scripts/build-icon.py) uses macOS `sips` to create 16, 32, 64, 128, 256, 512, and 1024-pixel PNG representations in `.build/Sloth.iconset/`, then packages them into [Resources/Sloth.icns](../Resources/Sloth.icns). The build script copies that ICNS file into `build/Sloth.app/Contents/Resources/`. `Resources/Info.plist` selects it through `CFBundleIconFile = Sloth`.

The source PNG and packaged ICNS are included as project assets; a normal app build does not regenerate the artwork.
