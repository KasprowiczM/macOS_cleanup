"""Localized strings for the terminal interface in the seven toolkit languages;
no runtime I/O.

Catalogs live in tui_strings (English, Polish) and tui_strings_intl (German,
Spanish, French, Italian, Portuguese). A key missing from a language falls back
to English, then to a readable form of the key itself, so a missing string never
crashes a running interface.
"""
from tui_strings import STRINGS

LANGUAGES = ("en", "pl", "de", "es", "fr", "it", "pt")

CATALOGS = {lang: dict(STRINGS['en']) for lang in LANGUAGES}
for _lang in LANGUAGES:
    CATALOGS[_lang].update(STRINGS.get(_lang, {}))


def humanize(key):
    """Readable fallback for a key that has no string at all."""
    return key.split('_', 1)[-1].replace('_', ' ')


def tr(key, lang="en", **values):
    """Translate a closed UI key; unsupported languages use English.

    Missing values remain visible rather than crashing a running dashboard.
    User-provided values are text only and never become catalog keys or code.
    """
    catalog = CATALOGS.get(lang, CATALOGS["en"])
    template = catalog.get(key)
    if template is None:
        template = CATALOGS["en"].get(key)
    if template is None:
        return key
    if not values:
        return template
    try:
        return template.format(**values)
    except (KeyError, ValueError, IndexError):
        return template


def untranslated(lang):
    """Keys of the English catalog that ``lang`` does not translate itself."""
    if lang == 'en':
        return []
    own = STRINGS.get(lang, {})
    return sorted(k for k in STRINGS['en'] if k not in own)
