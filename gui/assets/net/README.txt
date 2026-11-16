Rapp network status icons

strong = cheetah; normal = rabbit; weak = turtle; offline = cracked egg.
Each base PNG: exactly 28 x 14 pixels, black RGBA on transparent background.
@2x: 56 x 28 pixels; @3x: 84 x 42 pixels. Display all at 28 x 14 points.
Four Xcode .imageset folders are included. Render as template images for light/dark tint.
Artwork is optically sized independently within identical canvases.
The horizontal angular egg fracture is adjusted for small-size legibility.
preview.png: top row native 1x; bottom row 8x nearest-neighbor pixel inspection.

Imported into the Flutter GUI (2026-11-16): the four PNGs are asset variants under
assets/net/ — strong.png (cheetah), ok.png (rabbit, was normal), weak.png (tortoise),
down.png (cracked egg, was offline) — with 2.0x/ and 3.0x/ beside them, so the names match
NetLevel. The Xcode .imageset folders are not used: this app is Flutter, not AppKit, and the
same template rendering is done with Image.asset(color: ..., BlendMode.srcIn).
