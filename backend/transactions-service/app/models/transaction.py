import enum
from sqlalchemy import Column, Integer, String, Float, Enum, DateTime
from datetime import datetime
from app.core.database import Base

class TxType(str, enum.Enum):
    DEPOSIT = "deposit"
    WITHDRAWAL = "withdrawal"
    TRANSFER = "transfer"

class Transaction(Base):
    __tablename__ = "transactions"

    id = Column(Integer, primary_key=True, index=True)
    sender_account = Column(String, index=True, nullable=True)
    receiver_account = Column(String, index=True, nullable=False)
    amount = Column(Float, nullable=False)
    tx_type = Column(Enum(TxType), nullable=False)
    timestamp = Column(DateTime, default=datetime.utcnow)
