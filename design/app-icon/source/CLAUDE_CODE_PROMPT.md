Implement the QuranSpatial visionOS app icon using the PNG files in this folder.

First inspect the repository, its instructions, Xcode version, visionOS target, asset catalogs and current app-icon configuration. Preserve existing work and make a backup of the current icon assets. Modify only icon-related files and required target settings.

These six PNGs are editable SOURCE COMPONENTS, not six native visionOS layers:
01_glass_shell.png — optional decorative shell
02_gold_arch.png — ornate arch
03_night_environment.png — sky, crescent, mountains and lake
04_floating_quran.png — central book
05_gold_platform.png — lower platform
06_lanterns.png — two side lanterns

All PNGs use the same square canvas. Do not trim transparent bounds or auto-center each object independently. Preserve relative alignment. These are AI-recreated components from a flattened reference, so inspect their composite before installation and make minimal placement corrections if needed. Do not present decorative page marks as verified Quranic text.

Apple visionOS supports a background plus one or two foreground layers, 1024×1024 pixels, with system circular masking. Configure a native visionOS image stack in Xcode's asset catalog; do not import all six as separate native layers and do not use the iOS Icon Composer workflow by assumption.

Generate these three final PNGs using ordinary image compositing:
QuranSpatial_AppIcon_Background_1024.png: full-bleed opaque dark-navy backdrop with 03_night_environment composited over it. Extend or blend its perimeter so there is no visible rectangular card edge inside the circular crop.
QuranSpatial_AppIcon_Middle_1024.png: transparent canvas, gold platform first, then gold arch, then side lanterns.
QuranSpatial_AppIcon_Foreground_1024.png: transparent canvas containing only the floating Quran.

Do not bake 01_glass_shell into the production icon by default: its rounded-square rim conflicts with the system's circular mask. Keep it as an optional editable concept component. Do not add captions or a pre-applied circular/rounded-square mask to final assets. Retain sRGB, use high-quality resampling if needed, and preserve genuine alpha in Middle and Foreground. The Background must be completely opaque.

Before installing, render a flat composite and a circular-mask QA preview at 1024, 128 and 64 pixels. Check that the Quran is recognizable, the arch peak and lanterns survive cropping, there are no checkerboard pixels baked into images, alpha edges look clean, and the book does not overlap the platform awkwardly. If the overall composition needs shrinking, apply the same transform to every component and fill the exposed background.

Create/update the correct visionOS AppIcon image stack using the schema supported by this project's installed Xcode. Inspect an existing working image stack or a temporary Xcode-generated template rather than guessing Contents.json keys. Ensure the target references the correct icon asset name. Preserve other platform icons.

Build the visionOS target and report the build result and changed paths. If headset access exists, preview the circular icon and native parallax there; otherwise clearly say device appearance remains unverified. Do not claim simulator/device testing that was not performed. No unrelated refactoring or automatic commit.

Official references:
https://developer.apple.com/design/human-interface-guidelines/app-icons/
https://developer.apple.com/documentation/xcode/configuring-your-app-icon
