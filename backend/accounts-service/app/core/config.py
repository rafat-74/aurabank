from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql://aura_accounts_admin:SuperSecureAccountsPassword2026@aurabank-accounts-db:5432/aurabank_accounts"
    SECRET_KEY: str = "SUPER_SECRET_KEY_FOR_JWT_SIGNING_2026_LEET"
    ALGORITHM: str = "HS256"

    class Config:
        env_file = ".env"

settings = Settings()
