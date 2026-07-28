from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
import random

from app.core.database import get_db
from app.models.account import Account
from app.schemas.account import AccountCreate, AccountResponse, BalanceUpdate

router = APIRouter(prefix="/accounts", tags=["accounts"])

@router.post("/create", response_model=AccountResponse, status_code=status.HTTP_201_CREATED)
def create_account(account: AccountCreate, db: Session = Depends(get_db)):
    acc_num = "".join([str(random.randint(0, 9)) for _ in range(10)])
    new_account = Account(
        account_number=acc_num,
        username=account.username,
        balance=account.initial_deposit,
        currency=account.currency
    )
    db.add(new_account)
    db.commit()
    db.refresh(new_account)
    return new_account

@router.get("/me/{username}", response_model=AccountResponse)
def get_my_account(username: str, db: Session = Depends(get_db)):
    account = db.query(Account).filter(Account.username == username).first()
    if not account:
        raise HTTPException(status_code=404, detail="Account not found")
    return account

@router.put("/{account_number}/freeze", response_model=AccountResponse)
def freeze_account(account_number: str, db: Session = Depends(get_db)):
    account = db.query(Account).filter(Account.account_number == account_number).first()
    if not account:
        raise HTTPException(status_code=404, detail="Account not found")
    account.is_frozen = True
    db.commit()
    db.refresh(account)
    return account

@router.put("/{account_number}/update-balance")
def update_balance(account_number: str, update: BalanceUpdate, db: Session = Depends(get_db)):
    account = db.query(Account).filter(Account.account_number == account_number).first()
    if not account:
        raise HTTPException(status_code=404, detail="Account not found")
    if account.is_frozen:
        raise HTTPException(status_code=400, detail="Account is frozen")
    
    account.balance += update.amount
    if account.balance < 0:
        raise HTTPException(status_code=400, detail="Insufficient funds")
        
    db.commit()
    return {"status": "success", "new_balance": account.balance}
