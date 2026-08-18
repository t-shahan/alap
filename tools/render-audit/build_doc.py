import os
HERE = os.path.dirname(os.path.abspath(__file__))
import re, subprocess, sys, os

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "..", "app", "Sources", "Alap", "Views", "MessageWebView.swift")

def css(is_dark=True):
    """Extract the CSS literal from css(isDark:) and resolve its interpolations."""
    s = open(SRC).read()
    i = s.index("private static func css(isDark: Bool) -> String {")
    body = s[i:]
    vals = {}
    for name in ["text", "secondary", "rule", "link"]:
        m = re.search(rf'let {name} = isDark \? "([^"]+)" : "([^"]+)"', body)
        vals[name] = m.group(1) if is_dark else m.group(2)
    start = body.index('return """') + len('return """')
    end = body.index('"""', start)
    out = body[start:end]
    out = out.replace(r'\(isDark ? "dark" : "light")', "dark" if is_dark else "light")
    for name, v in vals.items():
        out = out.replace(f'\\({name})', v)
    return out.strip()

def restore_images(html):
    return html.replace('data-blocked-src="', 'src="').replace('data-blocked="remote"', '')

def build(html, show_remote=True, is_dark=True, has_html=True):
    # Mirrors MessageDocument.build: a light canvas only when the message
    # brings colours of its own.
    import re
    brings = any(re.search(m, html, re.I) for m in
                 ["bgcolor", "background", "color:", "color=", "<font"])
    is_dark = is_dark and not (has_html and brings)
    if show_remote:
        html = restore_images(html)
    img_src = "img-src cid: data: https:" if show_remote else "img-src cid: data:"
    upgrade = " upgrade-insecure-requests;" if show_remote else ""
    return f"""<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy"
      content="default-src 'none'; {img_src}; style-src 'unsafe-inline'; font-src 'none'; form-action 'none'; base-uri 'none';{upgrade}">
<style>{css(is_dark)}</style>
</head><body><article>{html}</article></body></html>"""

if __name__ == "__main__":
    print(css()[:400])

def app_fit_script():
    """The app's own fit-and-measure JS, lifted from the source.

    Extracted rather than copied so the harness cannot drift from the app and
    quietly start validating something the app no longer does.
    """
    s = open(SRC).read()
    i = s.index("private static let fitAndMeasure = \"\"\"")
    start = s.index("\n", i) + 1
    end = s.index('"""', start)
    return s[start:end]
