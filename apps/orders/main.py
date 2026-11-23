"""orders: place an order = reserve stock (inventory) + charge (payments) + save (Postgres).

No tracing / OpenTelemetry code on purpose: OBI must see it from the kernel.

Handlers are plain `def` (not async): FastAPI runs them in a thread pool.
This is the simpler case for OBI's Python context tracking (asyncio is a known caveat).

Env: INVENTORY_URL, PAYMENTS_URL, DATABASE_URL
"""
import os
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException
from psycopg_pool import ConnectionPool
from pydantic import BaseModel

INVENTORY_URL = os.getenv("INVENTORY_URL", "http://inventory:8080")
PAYMENTS_URL = os.getenv("PAYMENTS_URL", "http://payments:5000")
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://shop:shop@postgres:5432/shop")
PRICES = {"apple": 1.5, "banana": 0.5, "cherry": 4.0}

http = httpx.Client(timeout=5.0)
pool = ConnectionPool(DATABASE_URL, min_size=1, max_size=4, open=False)


class OrderIn(BaseModel):
    item: str
    qty: int


def init_db():
    # Wait for Postgres, then create the table.
    for _ in range(30):
        try:
            pool.open(wait=True, timeout=5)
            with pool.connection() as conn:
                conn.execute(
                    """CREATE TABLE IF NOT EXISTS orders (
                           id SERIAL PRIMARY KEY,
                           item TEXT NOT NULL,
                           qty INT NOT NULL,
                           amount NUMERIC(10,2) NOT NULL,
                           status TEXT NOT NULL,
                           created_at TIMESTAMPTZ DEFAULT now())"""
                )
            return
        except Exception as e:  # noqa: BLE001
            print(f"waiting for postgres: {e}", flush=True)
            time.sleep(2)
    raise RuntimeError("postgres not reachable")


@asynccontextmanager
async def lifespan(_app):
    init_db()
    yield
    pool.close()


app = FastAPI(lifespan=lifespan)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/orders")
def list_orders(limit: int = 10):
    with pool.connection() as conn:
        rows = conn.execute(
            "SELECT id, item, qty, amount, status, created_at FROM orders ORDER BY id DESC LIMIT %s",
            (limit,),
        ).fetchall()
    return [
        {"id": r[0], "item": r[1], "qty": r[2], "amount": float(r[3]), "status": r[4], "created_at": r[5].isoformat()}
        for r in rows
    ]


@app.post("/orders")
def create_order(order: OrderIn):
    if order.item not in PRICES or order.qty <= 0:
        raise HTTPException(400, "unknown item or qty <= 0")
    amount = round(PRICES[order.item] * order.qty, 2)

    # 1. reserve stock
    r = http.post(f"{INVENTORY_URL}/reserve", json={"item": order.item, "qty": order.qty})
    if r.status_code != 200:
        raise HTTPException(r.status_code, f"inventory: {r.json().get('error')}")

    # 2. charge
    with pool.connection() as conn:
        order_id = conn.execute(
            "INSERT INTO orders (item, qty, amount, status) VALUES (%s, %s, %s, 'pending') RETURNING id",
            (order.item, order.qty, amount),
        ).fetchone()[0]
    p = http.post(f"{PAYMENTS_URL}/pay", json={"order_id": order_id, "amount": amount})
    status = "paid" if p.status_code == 200 else "payment_failed"

    # 3. save result
    with pool.connection() as conn:
        conn.execute("UPDATE orders SET status = %s WHERE id = %s", (status, order_id))

    if status != "paid":
        raise HTTPException(502, f"payment failed for order {order_id}")
    return {"id": order_id, "item": order.item, "qty": order.qty, "amount": amount, "status": status}
