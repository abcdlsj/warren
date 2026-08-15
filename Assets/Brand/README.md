# Warren Brand

## Core Concept

The logo combines the letter `W`, a rabbit-warren burrow, and a terminal cursor in one pixel mark.

- The two raised strokes read as rabbit ears and form the opening and closing strokes of the `W`.
- The forked shape below suggests connected burrows, echoing the name Warren and how Workspaces are organized.
- The amber square is both a light inside the burrow and a terminal cursor.

## Responsive Source Files

- `warren-app-icon.svg`: 1024 × 1024 master source used at 64 px and above.
- `warren-app-icon-32.svg`: native 32 × 32 compact version. Keeps one depth layer and removes inner light/shadow faces.
- `warren-app-icon-16.svg`: native 16 × 16 miniature version. Keeps only the base plate, the `W`, and the cursor.
- `warren-app-icon.png`: 1024 × 1024 preview and general bitmap.
- `Warren.icns`: macOS app icon.

Do not scale the master SVG down to 16 px directly. The master artwork uses a 32 px construction grid, so scaling to 16 px produces half-pixel edges. After modifying any source file, run:

```sh
mise run brand:assets
mise run web:build
```

The first command generates the macOS iconset, ICNS, Web favicons, and PWA PNGs; the second builds `Web/public/` into `Web/dist/`. Derived files must not be edited by hand.

## Colors

| Use | Value |
| --- | --- |
| Main background | `#1c1918` |
| Deep shadow | `#0f0d0c` |
| Main mark | `#eae8e6` |
| Cursor | `#f59e0b` |

Do not add gradients, rounded strokes, or anti-aliased strokes. The artwork must stay aligned to the 32 px construction grid so it remains crisp at small sizes.
