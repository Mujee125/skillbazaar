import re

_E164 = re.compile(r"[1-9][0-9]{7,14}")
_PK_MOBILE = re.compile(r"923[0-9]{9}")


class InvalidPhone(ValueError):
    pass


def normalize_phone(raw):
    """Return E.164 (+<country><number>) or raise InvalidPhone.

    '+' or '00' prefix = international number.
    No prefix = Pakistani number. Pakistani numbers must be mobiles.
    """
    text = re.sub(r"[\s\-().]", "", raw or "")
    if text.startswith("+"):
        digits = text[1:]
    elif text.startswith("00"):
        digits = text[2:]
    elif text.startswith("92"):
        digits = text
    elif text.startswith("0"):
        digits = "92" + text[1:]
    else:
        digits = "92" + text
    if not _E164.fullmatch(digits):
        raise InvalidPhone("Not a valid number. Foreign numbers need + and country code.")
    if digits.startswith("92") and not _PK_MOBILE.fullmatch(digits):
        raise InvalidPhone("Pakistani numbers must be mobile: +92 3xx xxxxxxx")
    return "+" + digits
