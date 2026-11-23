"""payments: fake payment service.

No tracing / OpenTelemetry code on purpose: OBI must see it from the kernel.

Env vars (used in Phase 6 to create incidents):
  DELAY_MS_MAX  random delay 0..N ms per payment   (default 50)
  ERROR_RATE    fraction of payments that fail 0..1 (default 0.02)
"""
import os
import random
import time
import uuid

from flask import Flask, jsonify, request

app = Flask(__name__)

DELAY_MS_MAX = int(os.getenv("DELAY_MS_MAX", "50"))
ERROR_RATE = float(os.getenv("ERROR_RATE", "0.02"))


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/pay")
def pay():
    body = request.get_json(silent=True) or {}
    order_id = body.get("order_id")
    amount = body.get("amount")
    if order_id is None or amount is None:
        return jsonify(error="order_id and amount are required"), 400

    time.sleep(random.uniform(0, DELAY_MS_MAX) / 1000)

    if random.random() < ERROR_RATE:
        return jsonify(error="payment gateway failure", order_id=order_id), 500

    return jsonify(status="paid", payment_id=str(uuid.uuid4()), order_id=order_id, amount=amount)
