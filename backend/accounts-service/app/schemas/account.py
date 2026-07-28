from pydantic import BaseModel

class AccountBase(BaseModel):
    account_number: str
    currency: str = "EGP"

class AccountCreate(AccountBase):
    username: str
    initial_deposit: float = 0.0

class AccountResponse(AccountBase):
    id: int
    username: str
    balance: float
    is_frozen: bool

    class Config:
        from_attributes = True

class BalanceUpdate(BaseModel):
    amount: float
