import os
HERE = os.path.dirname(os.path.abspath(__file__))
import re, subprocess, sys, os

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "..", "app", "Sources", "Alap", "Views", "MessageWebView.swift")

def _stylesheet(fn, is_dark):
    """Extract one CSS literal from the app and resolve its interpolations.

    Parsed out of the source rather than copied, so the harness cannot drift
    from the app and quietly start validating something the app no longer does.
    """
    s = open(SRC).read()
    i = s.index(f"private static func {fn}(isDark: Bool) -> String {{")
    body = s[i:]
    end_of_fn = body.index('\n  }')
    decls = body[:end_of_fn]
    vals = {}
    for name in ["text", "secondary", "rule", "link", "canvas"]:
        m = re.search(rf'let {name} = isDark \? "([^"]+)" : "([^"]+)"', decls)
        if m:
            vals[name] = m.group(1) if is_dark else m.group(2)
    start = body.index('return """') + len('return """')
    end = body.index('"""', start)
    out = body[start:end]
    out = out.replace(r'\(isDark ? "dark" : "light")', "dark" if is_dark else "light")
    for name, v in vals.items():
        out = out.replace(f'\\({name})', v)
    return out.strip()


def css(is_dark=True):
    """The app's page defaults — kept for callers that want just the head sheet."""
    return _stylesheet("baseCSS", is_dark)


def chrome_css(is_dark=True):
    """The app's own chrome rules, which it now emits AFTER the bodies."""
    return _stylesheet("chromeCSS", is_dark)

def restore_images(html):
    return (html.replace('data-blocked-src="', 'src="')
                .replace('data-blocked="remote"', '')
                # The CSS half of the images preference: a remote
                # `background-image` is defused by rewriting its URL, because a
                # rule in a stylesheet has no element to hang an attribute on.
                .replace('"blocked-remote:', '"'))

def build(html, show_remote=True, is_dark=True, has_html=True):
    # Mirrors MessageDocument.build: a light canvas only when the message
    # brings colours of its own.
    import re
    # The bare `background` shorthand used to be in this list; it matched
    # `background-image`, `background-position` and any `class="background-cell"`
    # in retained markup, and the reasoning behind it ("`<style>` blocks are
    # dropped on ingest") stopped being true when the sanitiser kept them.
    brings = any(re.search(m, html, re.I) for m in
                 ["bgcolor", "background-color", "color:", "color=", "<font"])
    is_dark = is_dark and not (has_html and brings)
    if show_remote:
        html = restore_images(html)
    img_src = "img-src cid: data: https:" if show_remote else "img-src cid: data:"
    upgrade = " upgrade-insecure-requests;" if show_remote else ""
    # `#fit` is the fit pass's transform target, and the chrome sheet comes
    # after the bodies so the app wins specificity ties against a retained
    # sender stylesheet on document order. Both mirror `MessageDocument.build`.
    # Each message's own stylesheet is confined to its own article, mirroring
    # `MessageDocument.scoping(_:to:)`. Without this the harness would measure a
    # document the app no longer builds.
    scoped = scope_stylesheets(html, "alap-msg-0")
    return f"""<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy"
      content="default-src 'none'; {img_src}; style-src 'unsafe-inline'; font-src 'none'; form-action 'none'; base-uri 'none';{upgrade}">
<style>{css(is_dark)}</style>
</head><body><div id="fit"><article id="alap-msg-0" class="alap-msg">{scoped}</article></div>
<style>{chrome_css(is_dark)}</style>
</body></html>"""


def scope_stylesheets(html: str, scope: str) -> str:
    """Wrap every retained <style> block in `@scope (#scope) { ... }`.

    Mirrors `MessageDocument.scoping(_:to:)`. A text wrap rather than a selector
    rewrite: the sanitiser already refuses `<`, `>` and unbalanced braces inside
    a stylesheet, so a retained block cannot close its own `<style>` early or
    unbalance the wrapper.
    """
    import re
    out, pos = [], 0
    for m in re.finditer(r"<style[^>]*>", html, re.I):
        close = html.lower().find("</style", m.end())
        if close < 0:
            break
        out.append(html[pos:m.end()])
        out.append("@scope (#%s) {" % scope)
        out.append(html[m.end():close])
        out.append("}")
        pos = close
    out.append(html[pos:])
    return "".join(out)

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
