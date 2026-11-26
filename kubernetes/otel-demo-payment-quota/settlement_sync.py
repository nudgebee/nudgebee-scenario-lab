"""Settle the day's charges against the card processor through payment.

RATE charges a second across WORKERS threads, for DURATION_SECONDS.
"""
import os
import random
import threading
import time

import demo_pb2
import demo_pb2_grpc
import grpc

stub = demo_pb2_grpc.PaymentServiceStub(grpc.insecure_channel(os.environ["PAYMENT_ADDR"]))
workers = int(os.environ["WORKERS"])
rate = float(os.environ["RATE"]) / workers
duration = float(os.environ["DURATION_SECONDS"])
charge = demo_pb2.ChargeRequest(
    amount=demo_pb2.Money(currency_code="USD", units=42, nanos=0),
    credit_card=demo_pb2.CreditCardInfo(
        credit_card_number="4432-8015-6152-0454",
        credit_card_cvv=672,
        credit_card_expiration_year=2039,
        credit_card_expiration_month=1,
    ),
)
lock, counts = threading.Lock(), {"settled": 0, "deferred": 0}


def worker():
    # Spread the workers out rather than firing together.
    nxt = time.monotonic() + random.uniform(0, 1 / rate)
    while True:
        delay = nxt - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        try:
            stub.Charge(charge, timeout=5)
            outcome = "settled"
        except grpc.RpcError:
            outcome = "deferred"
        with lock:
            counts[outcome] += 1
        nxt = max(nxt, time.monotonic()) + random.uniform(0.5, 1.5) / rate


for _ in range(workers):
    threading.Thread(target=worker, daemon=True).start()
print(f"settlement batch started: {workers} workers", flush=True)
end = time.monotonic() + duration
while time.monotonic() < end:
    time.sleep(min(60, max(0, end - time.monotonic())))
    with lock:
        done = dict(counts)
        counts.update(settled=0, deferred=0)
    print(f"settlement batch: {done['settled']} settled, {done['deferred']} deferred to the next pass", flush=True)
print("settlement batch finished", flush=True)
try:  # send the last spans before the hard exit below skips the SDK's own shutdown
    from opentelemetry import trace

    getattr(trace.get_tracer_provider(), "shutdown", lambda: None)()
except Exception:
    pass
os._exit(0)
