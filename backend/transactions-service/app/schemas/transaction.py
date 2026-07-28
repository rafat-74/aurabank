from pydantic import BaseModel
from datetime import datetime
from app.models.transaction import TxType

class TransactionCreate(BaseModel):
    sender_account: str | None = None
    receiver_account: str
    amount: float
    tx_type: TxType

class TransactionResponse(TransactionCreate):
    id: int
    timestamp: datetime

    class Config:
        from_attributes = True
