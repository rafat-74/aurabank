from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql://aura_auth_admin:SuperSecureAuthPassword2026@aurabank-auth-db:5432/aurabank_auth"
    SECRET_KEY: str = "SUPER_SECRET_KEY_FOR_JWT_SIGNING_2026_LEET"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30

    class Config:
        env_file = ".env"

settings = Settings()