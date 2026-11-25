# Zadur icon kit

Zadur’s primary icon is a lowercase serif **z**, a black **period** on the baseline, and an oxblood insertion cursor. The paper and letterpress ink come from the first design. The plain z is included as an optional alternate. Open `Preview.png` to see both at app-icon and Finder sizes.

## Use in Xcode

1. If the target already contains an icon set named `AppIcon`, rename that existing set in Xcode to keep a copy.
2. Drag `ZadurIcons.xcassets` into your project and include it in the iOS and macOS targets that will use it. You can also drag the individual `AppIcon.appiconset` folder into an existing asset catalog.
3. In each target’s **Build Settings**, use `AppIcon` for **Primary App Icon Set Name** (`ASSETCATALOG_COMPILER_APPICON_NAME`). This selects the period design for iPhone, iPad, the App Store and Mac.

To offer the plain design as an in-app choice on iOS, also include `ZadurPlain.appiconset` and add `ZadurPlain` to **Alternate App Icon Sets** (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`). Pass `"ZadurPlain"` to `UIApplication.shared.setAlternateIconName(_:completionHandler:)` to select it, or pass `nil` to restore the period design.

## Files

| Location | Contents |
| --- | --- |
| `ZadurIcons.xcassets/` | Two Xcode app icon sets. The iOS PNGs are opaque and extend to all four corners. The system supplies their display mask. The Mac PNGs have a rounded paper silhouette, transparent margins and a subtle shadow. |
| `macOS/Zadur.icns` | Standalone Mac icon with the period. It carries 1× and 2× representations for 16, 32, 128, 256 and 512 points. |
| `Masters/Zadur.png` | Full-bleed primary artwork at its original 1254 × 1254 resolution. The 1024 × 1024 store export is `ZadurIcons.xcassets/AppIcon.appiconset/ios-1024.png`. |
| `Alternates/Plain/` | The plain z artwork and its standalone Mac `.icns`. Its Xcode set is named `ZadurPlain`. |
| `Reference/Original-Y.png` | The original cursor sketch used for both designs. |

The 16-pixel Finder icons use a closer crop so the period and red cursor remain distinguishable.

[Apple’s app icon guide](https://developer.apple.com/documentation/xcode/configuring-your-app-icon) · [Apple’s alternate icon guide](https://developer.apple.com/documentation/xcode/configuring-your-app-to-use-alternate-app-icons)
