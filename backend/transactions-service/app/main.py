from fastapi import FastAPI
from app.core.database import Base, engine
from app.routes import transactions

Base.metadata.create_all(bind=engine)

app = FastAPI(title="AuraBank Transactions Service", version="2.0.0")

@app.get("/health", tags=["monitoring"])
def health_check():
    return {"status": "healthy"}

app.include_router(transactions.router, prefix="/api/v1")
