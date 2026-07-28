from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
import httpx

from app.core.database import get_db
from app.core.config import settings
from app.models.transaction import Transaction, TxType
from app.schemas.transaction import TransactionCreate, TransactionResponse

router = APIRouter(prefix="/transactions", tags=["transactions"])

@router.post("/execute", response_model=TransactionResponse)
async def execute_transaction(tx: TransactionCreate, db: Session = Depends(get_db)):
    async with httpx.AsyncClient() as client:
        # خصم من الراسل لو سحب أو تحويل
        if tx.tx_type in [TxType.WITHDRAWAL, TxType.TRANSFER]:
            if not tx.sender_account:
                raise HTTPException(status_code=400, detail="Sender account required")
            
            res = await client.put(f"{settings.ACCOUNTS_SERVICE_URL}/accounts/{tx.sender_account}/update-balance", json={"amount": -tx.amount})
            if res.status_code != 200:
                raise HTTPException(status_code=res.status_code, detail=f"Sender error: {res.json().get('detail')}")

        # إضافة للمستلم لو إيداع أو تحويل
        if tx.tx_type in [TxType.DEPOSIT, TxType.TRANSFER]:
            res = await client.put(f"{settings.ACCOUNTS_SERVICE_URL}/accounts/{tx.receiver_account}/update-balance", json={"amount": tx.amount})
            if res.status_code != 200:
                # لو التحويل فشل في النص، نرجع الفلوس لحساب الراسل (Rollback)
                if tx.tx_type == TxType.TRANSFER:
                    await client.put(f"{settings.ACCOUNTS_SERVICE_URL}/accounts/{tx.sender_account}/update-balance", json={"amount": tx.amount})
                raise HTTPException(status_code=res.status_code, detail=f"Receiver error: {res.json().get('detail')}")

    new_tx = Transaction(**tx.model_dump())
    db.add(new_tx)
    db.commit()
    db.refresh(new_tx)
    return new_tx
