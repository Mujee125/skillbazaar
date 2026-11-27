import pytest
from django.db import IntegrityError, transaction
from django.db.models import ProtectedError
from django.utils import timezone

from modules.accounts.models import Account, AccountStatus, AccountType, User

pytestmark = pytest.mark.django_db


@pytest.fixture
def user():
    return User.objects.create_user("03001234567")


def test_create_user_normalizes_phone_and_has_no_password(user):
    assert user.phone_number == "+923001234567"
    assert not user.has_usable_password()


def test_foreign_number_is_accepted():
    assert User.objects.create_user("+14155550123").phone_number == "+14155550123"


def test_same_phone_cannot_make_a_second_user(user):
    with pytest.raises(IntegrityError), transaction.atomic():
        User.objects.create_user("+92 300 1234567")


@pytest.mark.parametrize("bad", ["03001234567", "+92211234567", "+1234"])
def test_db_rejects_bad_phone_even_without_python_checks(bad):
    with pytest.raises(IntegrityError), transaction.atomic():
        User.objects.create(phone_number=bad)


def test_one_user_holds_both_roles_with_independent_status(user):
    c = Account.objects.create(user=user, account_type=AccountType.CUSTOMER)
    p = Account.objects.create(
        user=user, account_type=AccountType.PROVIDER, status=AccountStatus.SUSPENDED
    )
    assert user.accounts.count() == 2
    assert Account.objects.get(pk=c.pk).status == AccountStatus.ACTIVE
    assert Account.objects.get(pk=p.pk).status == AccountStatus.SUSPENDED


def test_second_account_of_same_type_fails(user):
    Account.objects.create(user=user, account_type=AccountType.CUSTOMER)
    with pytest.raises(IntegrityError), transaction.atomic():
        Account.objects.create(user=user, account_type=AccountType.CUSTOMER)


def test_deactivated_account_still_blocks_a_duplicate(user):
    Account.objects.create(
        user=user,
        account_type=AccountType.CUSTOMER,
        status=AccountStatus.DEACTIVATED,
        deactivated_at=timezone.now(),
    )
    with pytest.raises(IntegrityError), transaction.atomic():
        Account.objects.create(user=user, account_type=AccountType.CUSTOMER)


@pytest.mark.parametrize(
    "kwargs", [{"account_type": "ADMIN"}, {"status": "BANNED"}]
)
def test_db_rejects_unknown_type_or_status(user, kwargs):
    data = {"account_type": AccountType.CUSTOMER, **kwargs}
    with pytest.raises(IntegrityError), transaction.atomic():
        Account.objects.create(user=user, **data)


@pytest.mark.parametrize(
    "status, stamp",
    [(AccountStatus.DEACTIVATED, None), (AccountStatus.ACTIVE, timezone.now())],
)
def test_deactivated_at_must_match_status(user, status, stamp):
    with pytest.raises(IntegrityError), transaction.atomic():
        Account.objects.create(
            user=user,
            account_type=AccountType.CUSTOMER,
            status=status,
            deactivated_at=stamp,
        )


def test_reactivation_clears_deactivated_at(user):
    acc = Account.objects.create(
        user=user,
        account_type=AccountType.CUSTOMER,
        status=AccountStatus.DEACTIVATED,
        deactivated_at=timezone.now(),
    )
    acc.status = AccountStatus.ACTIVE
    acc.deactivated_at = None
    acc.save()
    acc.refresh_from_db()
    assert acc.status == AccountStatus.ACTIVE
    assert acc.deactivated_at is None


def test_user_with_accounts_is_protected_from_delete(user):
    Account.objects.create(user=user, account_type=AccountType.CUSTOMER)
    with pytest.raises(ProtectedError):
        user.delete()
