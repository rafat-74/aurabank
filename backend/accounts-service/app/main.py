from fastapi import FastAPI
from app.core.database import Base, engine
from app.routes import accounts

Base.metadata.create_all(bind=engine)

app = FastAPI(title="AuraBank Accounts Service", version="2.0.0")

@app.get("/health", tags=["monitoring"])
def health_check():
    return {"status": "healthy"}

app.include_router(accounts.router, prefix="/api/v1")
