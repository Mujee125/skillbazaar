import pytest

from modules.accounts.phone import InvalidPhone, normalize_phone

PK = "+923001234567"


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("03001234567", PK),
        ("+923001234567", PK),
        ("923001234567", PK),
        ("0092 300 1234567", PK),
        ("0300-1234567", PK),
        ("+14155550123", "+14155550123"),
        ("0044 20 7946 0958", "+442079460958"),
    ],
)
def test_valid_numbers_are_normalized(raw, expected):
    assert normalize_phone(raw) == expected


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "abc",
        "0211234567",
        "030012345",
        "+9230012345678",
        "14155550123",
        "+1234",
        "+0123456789",
        "+92211234567",
    ],
)
def test_invalid_numbers_are_rejected(raw):
    with pytest.raises(InvalidPhone):
        normalize_phone(raw)
