# Mac Doctor app icon — placeholder specification

This is a deliberately simple placeholder so the Phase 1 `.app` has a real
icon. Replace it with original artwork before public distribution.

## Master

- 1024 × 1024 px PNG, RGBA, sRGB.
- Transparent canvas.
- Icon shape inset 82 px from every edge (860 × 860).
- Continuous-corner square with a 196 px corner radius.
- Gradient: `#2EBAB0` (top-left) → `#0D6660` (bottom-right).
- White stethoscope glyph centred in the shape, maximum dimension 520 px.
- Soft black drop shadow: 38 px blur, 16 px downward offset, 30% opacity.
- Hairline inner highlight: white at 18% opacity, 3 px.

## Asset catalog sizes

The master is downsampled with `/usr/bin/sips` into the standard macOS set:

| File | Pixels |
| --- | ---: |
| `icon_16x16.png` | 16 |
| `icon_16x16@2x.png` | 32 |
| `icon_32x32.png` | 32 |
| `icon_32x32@2x.png` | 64 |
| `icon_128x128.png` | 128 |
| `icon_128x128@2x.png` | 256 |
| `icon_256x256.png` | 256 |
| `icon_256x256@2x.png` | 512 |
| `icon_512x512.png` | 512 |
| `icon_512x512@2x.png` | 1024 |

## Regenerate

From the repository root:

```sh
/usr/bin/swift Tools/generate_placeholder_icon.swift
/usr/bin/sips -z 16 16 MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png \
  --out MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_16x16.png
/usr/bin/sips -z 32 32 MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png \
  --out MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png
/usr/bin/sips -z 32 32 MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png \
  --out MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32.png
/usr/bin/sips -z 64 64 MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png \
  --out MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png
/usr/bin/sips -z 128 128 MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png \
  --out MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png
/usr/bin/sips -z 256 256 MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png \
  --out MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png
/usr/bin/sips -z 256 256 MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png \
  --out MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png
/usr/bin/sips -z 512 512 MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png \
  --out MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png
/usr/bin/sips -z 512 512 MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png \
  --out MacDoctor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png
```

`icon_512x512@2x.png` is already the 1024 px master.

## Production note

The stethoscope is an SF Symbol used here as a placeholder mark. Commission a
custom stethoscope or pulse mark for a shipping release, then repeat the size
export above.
