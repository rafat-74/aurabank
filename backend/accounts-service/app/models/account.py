from sqlalchemy import Column, Integer, String, Float, Boolean
from app.core.database import Base

class Account(Base):
    __tablename__ = "accounts"

    id = Column(Integer, primary_key=True, index=True)
    account_number = Column(String, unique=True, index=True, nullable=False)
    username = Column(String, index=True, nullable=False)
    balance = Column(Float, default=0.0, nullable=False)
    currency = Column(String, default="EGP", nullable=False)
    is_frozen = Column(Boolean, default=False)
