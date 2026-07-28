from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql://aura_tx_admin:SuperSecureTxPassword2026@aurabank-transactions-db:5432/aurabank_transactions"
    ACCOUNTS_SERVICE_URL: str = "http://aurabank-accounts-service:8002/api/v1"

    class Config:
        env_file = ".env"

settings = Settings()
