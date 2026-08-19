"""WCAG 2.1 contrast arithmetic for the app's palettes.

Design-time mirror of `ThemeTests.swift`. The review (DESIGN-REVIEW.md §9.1)
records the methodological error that let six contrast failures ship: every
token was reasoned about against `base` alone. A token has to clear its floor
on the WORST surface it can land on, which is the *lightest* surface on a dark
palette and the *darkest* on a light one — the inverse of what the old
`Theme.swift` comment assumed.

Run it directly to re-verify the shipped palettes:

    python3 tools/palette-audit/contrast.py
"""

from __future__ import annotations


def _lin(c: float) -> float:
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(hexv: int) -> float:
    return (0.2126 * _lin((hexv >> 16) & 255)
            + 0.7152 * _lin((hexv >> 8) & 255)
            + 0.0722 * _lin(hexv & 255))


def contrast(a: int, b: int) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def composite(fg: int, alpha: float, bg: int) -> int:
    """Flatten a translucent foreground onto an opaque background."""
    out = 0
    for shift in (16, 8, 0):
        f, b = (fg >> shift) & 255, (bg >> shift) & 255
        out |= int(round(f * alpha + b * (1 - alpha))) << shift
    return out


def worst_case(token: int, alpha: float, surfaces) -> float:
    """The floor a token actually has to clear: its worst surface, not its base."""
    return min(contrast(composite(token, alpha, s), s) for s in surfaces)


# The shipped palettes. Kept in step with `Views/Theme.swift` by hand; the Swift
# tests are the gate, this is the calculator you reach for while choosing a value.
SIGNATURE = dict(
    base=0x0E161E, sunken=0x161E26, raised=0x192129, control=0x252D35,
    selection=0x1F2C3F, border=0x323A42, borderStrong=0x737B83,
    inkPrimary=(0xE9ECF3, 1.0), inkSecondary=(0xEBEBF5, 0.60),
    inkTertiary=(0xEBEBF5, 0.56), inkDisabled=(0xEBEBF5, 0.36),
    accentBlue=0x0B62D6, accentBlueText=0x4DA3FF, accentRed=0xFF453A,
    accentFlag=0xFF9F0A, accentMuted=0x6B7280, accentMutedInk=0x9AA3B2,
    accentOk=0x4CB06E,
)

DARK = dict(
    SIGNATURE,
    base=0x161617, sunken=0x1E1E20, raised=0x212124, control=0x2C2C2E,
    selection=0x2A2A2D, border=0x3A3A3C, borderStrong=0x7A7A7C,
    inkPrimary=(0xFFFFFF, 1.0),
)

LIGHT = dict(
    base=0xEAEEF4, sunken=0xDEE4EC, raised=0xFFFFFF, control=0xD1D9E4,
    selection=0xD3E4FB, border=0xC2CBD8, borderStrong=0x6E747A,
    inkPrimary=(0x0D141C, 1.0), inkSecondary=(0x000000, 0.65),
    inkTertiary=(0x000000, 0.60), inkDisabled=(0x000000, 0.45),
    accentBlue=0x0A6FE8, accentBlueText=0x0B55B8, accentRed=0xB00010,
    accentFlag=0xA45F0F, accentMuted=0x5F6772, accentMutedInk=0x565D67,
    accentOk=0x24693C,
)

PALETTES = {"Signature": SIGNATURE, "Dark": DARK, "Light": LIGHT}

#: `AccountPalette` in `AccountViews.swift` — a SECOND colour system, chosen
#: for mutual distinguishability rather than for contrast, and for a long time
#: never run through any of this. Its marker draws the account's initial on the
#: account's own fill, and against a white letter seven of these eight failed
#: 4.5:1. The two that failed worst are the two assigned first.
ACCOUNT_PALETTE = [
    ("Teal", 0x4AA3A2), ("Clay", 0xC2705A), ("Slate", 0x5B7BA8), ("Sage", 0x7D9A6D),
    ("Plum", 0x8A6A9E), ("Amber", 0xC39A4E), ("Rose", 0xB5697F), ("Steel", 0x6F7D8C),
]


def readable_ink(fill: int) -> int:
    """Black or white, whichever the fill can carry. Mirrors `AccountMarker`."""
    return 0x000000 if luminance(fill) > 0.179 else 0xFFFFFF

#: Ink is never drawn on `border`, so it is not a drawable surface.
DRAWABLE = ("base", "sunken", "raised", "control", "selection")

TEXT_FLOOR = 4.5
GRAPHICAL_FLOOR = 3.0


def _report(palette: dict, name: str) -> list[str]:
    surfaces = [palette[s] for s in DRAWABLE]
    failures = []

    def check(label, value, alpha, floor):
        worst = worst_case(value, alpha, surfaces)
        mark = "ok " if worst >= floor else "FAIL"
        print(f"  {mark} {label:<16} {worst:5.2f}  (floor {floor})")
        if worst < floor:
            failures.append(f"{name}: {label} at {worst:.2f}")

    print(f"\n{name}")
    for token in ("inkPrimary", "inkSecondary", "inkTertiary"):
        value, alpha = palette[token]
        check(token, value, alpha, TEXT_FLOOR)
    value, alpha = palette["inkDisabled"]
    worst = worst_case(value, alpha, surfaces)
    print(f"  --  {'inkDisabled':<16} {worst:5.2f}  (target 2.5-3, exempt)")

    for token in ("accentBlueText", "accentMutedInk", "accentOk"):
        check(token, palette[token], 1.0, TEXT_FLOOR)
    for token in ("accentFlag", "accentRed", "borderStrong"):
        check(token, palette[token], GRAPHICAL_FLOOR and 1.0, GRAPHICAL_FLOOR)

    white_on_blue = contrast(0xFFFFFF, palette["accentBlue"])
    mark = "ok " if white_on_blue >= TEXT_FLOOR else "FAIL"
    print(f"  {mark} {'white on blue':<16} {white_on_blue:5.2f}  (floor {TEXT_FLOOR})")
    if white_on_blue < TEXT_FLOOR:
        failures.append(f"{name}: white on accentBlue at {white_on_blue:.2f}")

    initials = contrast(
        composite(palette["accentMutedInk"], 1.0, composite(palette["accentMuted"], 0.13, palette["raised"])),
        composite(palette["accentMuted"], 0.13, palette["raised"]),
    )
    print(f"  {'ok ' if initials >= TEXT_FLOOR else 'FAIL'} {'avatar initials':<16} {initials:5.2f}")

    print("  separation:")
    for a, b in (("sunken", "base"), ("base", "raised"), ("sunken", "raised"),
                 ("control", "raised")):
        print(f"     {a:>8} / {b:<8} {contrast(palette[a], palette[b]):.2f}")
    return failures


def _report_accounts() -> list[str]:
    print("\nAccount markers (initial on the account's own fill)")
    failures = []
    for name, fill in ACCOUNT_PALETTE:
        ink = readable_ink(fill)
        ratio = contrast(ink, fill)
        chosen = "black" if ink == 0 else "white"
        mark = "ok " if ratio >= TEXT_FLOOR else "FAIL"
        print(f"  {mark} {name:<6} {chosen:<5} {ratio:5.2f}"
              f"   (white alone {contrast(0xFFFFFF, fill):5.2f})")
        if ratio < TEXT_FLOOR:
            failures.append(f"Account {name}: {ratio:.2f}")
    return failures


if __name__ == "__main__":
    problems = []
    for name, palette in PALETTES.items():
        problems += _report(palette, name)
    problems += _report_accounts()
    print()
    if problems:
        print("FAILURES")
        for line in problems:
            print(" ", line)
    else:
        print("All tokens clear their floors.")
