import pytest
from pydantic import ValidationError
from sqlalchemy.engine import make_url

from app.config import Settings

PARTS = {
    "FINDINGS_DB_HOST": "db.internal",
    "FINDINGS_DB_NAME": "findings",
    "FINDINGS_DB_USER": "findings_app",
    # Characters a generated RDS password may contain, each of which breaks a naively
    # concatenated URL.
    "FINDINGS_DB_PASSWORD": "p@ss/w:rd#1?",
}


def test_url_is_built_from_parts_with_the_password_escaped(monkeypatch):
    for key, value in PARTS.items():
        monkeypatch.setenv(key, value)

    url = make_url(Settings(_env_file=None).database_url)

    assert url.drivername == "postgresql+asyncpg"
    assert (url.host, url.port, url.database) == ("db.internal", 5432, "findings")
    assert (url.username, url.password) == ("findings_app", "p@ss/w:rd#1?")


def test_partial_parts_are_rejected_rather_than_falling_back(monkeypatch):
    monkeypatch.setenv("FINDINGS_DB_HOST", "db.internal")

    with pytest.raises(ValidationError, match="must be set together"):
        Settings(_env_file=None)


def test_explicit_url_is_kept_when_no_parts_are_set(monkeypatch):
    for key in PARTS:
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("FINDINGS_DATABASE_URL", "postgresql+asyncpg://u:p@h:1/x_test")

    assert Settings(_env_file=None).database_url == "postgresql+asyncpg://u:p@h:1/x_test"
