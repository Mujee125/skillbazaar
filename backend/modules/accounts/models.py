import uuid

from django.conf import settings
from django.contrib.auth.models import AbstractBaseUser, BaseUserManager, PermissionsMixin
from django.db import models
from django.utils import timezone

from .phone import normalize_phone


class AccountType(models.TextChoices):
    CUSTOMER = "CUSTOMER", "Customer"
    PROVIDER = "PROVIDER", "Provider"


class AccountStatus(models.TextChoices):
    ACTIVE = "ACTIVE", "Active"
    SUSPENDED = "SUSPENDED", "Suspended"
    DEACTIVATED = "DEACTIVATED", "Deactivated"


class Language(models.TextChoices):
    UR = "ur", "Urdu"
    EN = "en", "English"


class UserManager(BaseUserManager):
    def create_user(self, phone_number, **extra):
        user = self.model(phone_number=normalize_phone(phone_number), **extra)
        user.set_unusable_password()
        user.save(using=self._db)
        return user


class User(AbstractBaseUser, PermissionsMixin):
    """One person = one normalized phone number. Roles live in Account."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    phone_number = models.CharField(max_length=16, unique=True)
    preferred_language = models.CharField(
        max_length=5, choices=Language.choices, default=Language.UR
    )
    created_at = models.DateTimeField(default=timezone.now)
    is_staff = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)

    USERNAME_FIELD = "phone_number"
    REQUIRED_FIELDS = []
    objects = UserManager()

    class Meta:
        constraints = [
            models.CheckConstraint(
                condition=models.Q(phone_number__regex=r"^\+[1-9][0-9]{7,14}$"),
                name="ck_user_phone_e164",
            ),
            models.CheckConstraint(
                condition=~models.Q(phone_number__startswith="+92")
                | models.Q(phone_number__regex=r"^\+923[0-9]{9}$"),
                name="ck_user_phone_pk_mobile",
            ),
        ]


class Account(models.Model):
    """A role (customer or provider) held by one User."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="accounts"
    )
    account_type = models.CharField(max_length=10, choices=AccountType.choices)
    status = models.CharField(
        max_length=12, choices=AccountStatus.choices, default=AccountStatus.ACTIVE
    )
    created_at = models.DateTimeField(default=timezone.now)
    deactivated_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["user", "account_type"], name="uq_account_user_type"
            ),
            models.CheckConstraint(
                condition=models.Q(account_type__in=AccountType.values),
                name="ck_account_type_valid",
            ),
            models.CheckConstraint(
                condition=models.Q(status__in=AccountStatus.values),
                name="ck_account_status_valid",
            ),
            models.CheckConstraint(
                condition=models.Q(status="DEACTIVATED", deactivated_at__isnull=False)
                | (~models.Q(status="DEACTIVATED") & models.Q(deactivated_at__isnull=True)),
                name="ck_account_deactivated_at_matches_status",
            ),
        ]
