from pydantic import model_validator
from pydantic_settings import BaseSettings
from sqlalchemy.engine import URL


class Settings(BaseSettings):
    """Configuration is read from FINDINGS_* environment variables or a .env file.

    database_url defaults to the local docker-compose database so a fresh checkout runs
    with `make run`. That default is for development only: set FINDINGS_DATABASE_URL
    explicitly anywhere else.

    On AWS the URL is assembled from FINDINGS_DB_* parts instead (see infra/). RDS keeps
    the master password in Secrets Manager and ECS injects it as its own variable, so the
    password never has to be written into Terraform state or a hand-built URL string.
    """

    database_url: str = "postgresql+asyncpg://genesis:genesis@localhost:55432/findings"

    db_host: str | None = None
    db_port: int = 5432
    db_name: str | None = None
    db_user: str | None = None
    db_password: str | None = None

    # Ingest limits. A scanner with a bad locator generator can emit one finding per DOM
    # node, so the payload is bounded and oversized batches are rejected rather than
    # truncated -- silently dropping half a report is worse than refusing it.
    max_findings_per_request: int = 500

    # Per-project write budget. In-process, so it holds for a single worker; the
    # multi-worker version belongs in Redis (see README, "Where Redis goes").
    rate_limit_requests: int = 60
    rate_limit_window_seconds: int = 60

    model_config = {"env_prefix": "FINDINGS_", "env_file": ".env"}

    @model_validator(mode="after")
    def _url_from_parts(self) -> "Settings":
        # All-or-nothing: a half-set group most likely means a missing secret, and quietly
        # falling back to the localhost default would hide that until the first query.
        parts = (self.db_host, self.db_name, self.db_user, self.db_password)
        if any(parts) and not all(parts):
            raise ValueError(
                "FINDINGS_DB_HOST, FINDINGS_DB_NAME, FINDINGS_DB_USER and "
                "FINDINGS_DB_PASSWORD must be set together"
            )
        if all(parts):
            # URL.create escapes the password; a generated one can contain '@', '/' or ':'.
            self.database_url = URL.create(
                "postgresql+asyncpg",
                username=self.db_user,
                password=self.db_password,
                host=self.db_host,
                port=self.db_port,
                database=self.db_name,
            ).render_as_string(hide_password=False)
        return self


settings = Settings()
