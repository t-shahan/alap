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
    base=0x03111F, sunken=0x0B1A29, raised=0x152433, control=0x243241,
    selection=0x0F3056, border=0x364351, borderStrong=0x74818F,
    inkPrimary=(0xE0E7EF, 1.0), inkSecondary=(0xE3ECF6, 0.62),
    inkTertiary=(0xE3ECF6, 0.58), inkDisabled=(0xE3ECF6, 0.33),
    accentBlue=0x0059BB, accentBlueText=0x59A8ED, accentRed=0xEF4C48,
    accentFlag=0xECAA2E, accentMuted=0x647587, accentMutedInk=0x92A6BB,
    accentOk=0x48B487, stateHover=(0xCFE0F5, 0.06), statePressed=(0xCFE0F5, 0.09),
)

# Spelled out in full rather than `dict(SIGNATURE, base=..., ...)`.
#
# It used to inherit from SIGNATURE and override only the surfaces, which was
# harmless for exactly as long as the two palettes shared every accent. They no
# longer do — signature has its own family now — and under the old form this
# tool would have reported SIGNATURE's accents as DARK's: agreeing with itself
# while disagreeing with the Swift, which is the one failure mode a mirror of
# another file's values must not have.
DARK = dict(
    base=0x161617, sunken=0x1E1E20, raised=0x212124, control=0x2C2C2E,
    selection=0x2A2A2D, border=0x3A3A3C, borderStrong=0x7A7A7C,
    inkPrimary=(0xFFFFFF, 1.0), inkSecondary=(0xEBEBF5, 0.62),
    inkTertiary=(0xEBEBF5, 0.58), inkDisabled=(0xEBEBF5, 0.36),
    accentBlue=0x0B62D6, accentBlueText=0x4DA3FF, accentRed=0xFF453A,
    accentFlag=0xFF9F0A, accentMuted=0x6B7280, accentMutedInk=0x9AA3B2,
    accentOk=0x4CB06E, stateHover=(0xFFFFFF, 0.06), statePressed=(0xFFFFFF, 0.09),
)

UMBER = dict(
    base=0x1A0C05, sunken=0x24150D, raised=0x2D1F17, control=0x3D2F27,
    selection=0x452A10, border=0x4D4038, borderStrong=0x8A7D75,
    inkPrimary=(0xEDE6DD, 1.0), inkSecondary=(0xF4EBE1, 0.62),
    inkTertiary=(0xF4EBE1, 0.58), inkDisabled=(0xF4EBE1, 0.33),
    accentBlue=0x005EB9, accentBlueText=0x64A8ED, accentRed=0xEB5056,
    accentFlag=0xEBC336, accentMuted=0x807063, accentMutedInk=0xB2A091,
    accentOk=0x6AB275, stateHover=(0xF5E9DA, 0.06), statePressed=(0xF5E9DA, 0.09),
)

LIGHT = dict(
    base=0xEAEEF4, sunken=0xDEE4EC, raised=0xFFFFFF, control=0xD1D9E4,
    selection=0xD3E4FB, border=0xC2CBD8, borderStrong=0x6E747A,
    inkPrimary=(0x0D141C, 1.0), inkSecondary=(0x000000, 0.65),
    inkTertiary=(0x000000, 0.60), inkDisabled=(0x000000, 0.45),
    accentBlue=0x0A6FE8, accentBlueText=0x0B55B8, accentRed=0xB00010,
    accentFlag=0xA45F0F, accentMuted=0x5F6772, accentMutedInk=0x565D67,
    accentOk=0x24693C, stateHover=(0x000000, 0.05), statePressed=(0x000000, 0.09),
)

VELLUM = dict(
    base=0xEDE8D8, sunken=0xE1DAC7, raised=0xFCFAF3, control=0xD8CEB9,
    selection=0xE7D3AA, border=0xCCC3AF, borderStrong=0x63594B,
    inkPrimary=(0x181007, 1.0), inkSecondary=(0x110904, 0.66),
    inkTertiary=(0x110904, 0.62), inkDisabled=(0x110904, 0.40),
    accentBlue=0x005BA7, accentBlueText=0x005698, accentRed=0x901818,
    accentFlag=0x905A00, accentMuted=0x645B4F, accentMutedInk=0x5C5245,
    accentOk=0x275E2B, stateHover=(0x1E1409, 0.05), statePressed=(0x1E1409, 0.09),
)

NOON = dict(
    base=0xE9EDF2, sunken=0xD7DDE4, raised=0xFFFFFF, control=0xB2BCC6,
    selection=0x8CBAEE, border=0xA5AEB9, borderStrong=0x37414B,
    inkPrimary=(0x04070A, 1.0), inkSecondary=(0x060A0E, 0.78),
    inkTertiary=(0x060A0E, 0.65), inkDisabled=(0x060A0E, 0.42),
    accentBlue=0x00468D, accentBlueText=0x004581, accentRed=0x820004,
    accentFlag=0x7D4C00, accentMuted=0x444D56, accentMutedInk=0x3C4651,
    accentOk=0x004F20, stateHover=(0x0B1017, 0.06), statePressed=(0x0B1017, 0.10),
)

PALETTES = {
    "Signature": SIGNATURE, "Dark": DARK, "Umber": UMBER,
    "Light": LIGHT, "Vellum": VELLUM, "Noon": NOON,
}

#: Which palettes are dark, for the checks whose direction depends on it.
DARK_PALETTES = ("Signature", "Dark", "Umber")

#: `AccountPalette` in `AccountViews.swift` — a SECOND colour system, chosen
#: for mutual distinguishability rather than for contrast, and for a long time
#: never run through any of this. Its marker draws the account's initial on the
#: account's own fill, and against a white letter seven of these eight failed
#: 4.5:1. The two that failed worst are the two assigned first.
#:
#: `ACCOUNT_STORED` is the vocabulary written to Postgres. It is never drawn:
#: the two sets below are, chosen per polarity, because a mid-lightness dot has
#: nowhere to get contrast from on a near-white ground — six of the eight fell
#: under 3:1 on the light theme, Amber at 1.83.
ACCOUNT_STORED = [
    ("Teal", 0x4AA3A2), ("Clay", 0xC2705A), ("Slate", 0x5B7BA8), ("Sage", 0x7D9A6D),
    ("Plum", 0x8A6A9E), ("Amber", 0xC39A4E), ("Rose", 0xB5697F), ("Steel", 0x6F7D8C),
]

ACCOUNT_DARK = [
    ("Teal", 0x4AA3A2), ("Clay", 0xC2705A), ("Slate", 0x5F80AF), ("Sage", 0x7D9A6D),
    ("Plum", 0x9371A8), ("Amber", 0xC39A4E), ("Rose", 0xB5697F), ("Steel", 0x72808F),
]

ACCOUNT_LIGHT = [
    ("Teal", 0x285858), ("Clay", 0x5F372C), ("Slate", 0x263446), ("Sage", 0x42523A),
    ("Plum", 0x362A3E), ("Amber", 0x6F572C), ("Rose", 0x54303B), ("Steel", 0x30363C),
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

    # Ink under an interaction overlay, on the panes a quiet button can sit on.
    #
    # Every floor above is measured against a surface AT REST. `.alap()` lays a
    # tint over whatever pane a control sits on when hovered or pressed, and on
    # a dark palette that LIGHTENS the ground under unchanged ink. At the old
    # 0.11 pressed tint, tertiary fell to 4.31:1 on `raised` — a control that
    # cleared the floor sitting still and failed it under the pointer.
    print("  under interaction overlays:")
    panes = [palette[s] for s in ("base", "sunken", "raised")]
    for state in ("stateHover", "statePressed"):
        overlay, overlay_alpha = palette[state]
        tinted = [composite(overlay, overlay_alpha, pane) for pane in panes]
        for token in ("inkSecondary", "inkTertiary"):
            value, alpha = palette[token]
            worst = worst_case(value, alpha, tinted)
            mark = "ok " if worst >= TEXT_FLOOR else "FAIL"
            print(f"     {mark} {token:<14} {state:<12} {worst:5.2f}")
            if worst < TEXT_FLOOR:
                failures.append(f"{name}: {token} under {state} at {worst:.2f}")

    print("  separation:")
    for a, b in (("sunken", "base"), ("base", "raised"), ("sunken", "raised"),
                 ("control", "raised")):
        print(f"     {a:>8} / {b:<8} {contrast(palette[a], palette[b]):.2f}")
    return failures


def _report_accounts() -> list[str]:
    """The initial on its own fill, AND the fill against every surface.

    The second half is the one that was missing. Checking a letter against the
    disc it sits on is a closed system: it never asks whether the disc can be
    seen. The thread-list rail is the same colour with no letter at all, so a
    fill under 3:1 is an ownership cue that simply is not there.
    """
    print("\nAccount markers (initial on the account's own fill)")
    failures = []
    for set_name, table in (("dark", ACCOUNT_DARK), ("light", ACCOUNT_LIGHT)):
        for name, fill in table:
            ink = readable_ink(fill)
            ratio = contrast(ink, fill)
            chosen = "black" if ink == 0 else "white"
            mark = "ok " if ratio >= TEXT_FLOOR else "FAIL"
            print(f"  {mark} {set_name:<5} {name:<6} {chosen:<5} {ratio:5.2f}")
            if ratio < TEXT_FLOOR:
                failures.append(f"Account {set_name} {name} initial: {ratio:.2f}")

    print("\nAccount fills against the surfaces they are drawn on")
    for palette_name, palette in PALETTES.items():
        table = ACCOUNT_DARK if palette_name in DARK_PALETTES else ACCOUNT_LIGHT
        surfaces = [palette[s] for s in DRAWABLE]
        worst_name, worst = None, 99.0
        for name, fill in table:
            ratio = min(contrast(fill, s) for s in surfaces)
            if ratio < worst:
                worst_name, worst = name, ratio
            if ratio < GRAPHICAL_FLOOR:
                failures.append(f"Account {name} on {palette_name}: {ratio:.2f}")
        mark = "ok " if worst >= GRAPHICAL_FLOOR else "FAIL"
        print(f"  {mark} {palette_name:<10} worst {worst:5.2f}  ({worst_name})")
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
