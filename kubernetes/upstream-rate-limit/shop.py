#!/usr/bin/env python3
"""One small service of the scenario's shop. ROLE picks which one.

  payments-gateway  the shop's gateway to its card processor. The processor allows
                    LIMIT calls a second for the whole merchant account, so every
                    caller shares one budget. Over it, callers get 429 Too Many Requests.
  checkout          takes an order and charges it through payments-gateway. A 429
                    from payments-gateway becomes a 503 for the shopper.
  storefront        the shoppers: RATE orders a second against checkout.
  ledger-reconcile  a batch job that re-checks charges against the processor through
                    payments-gateway: WORKERS threads, RATE_PER_WORKER calls a second each.

Every 10 seconds each service logs what happened in that window and serves the
same numbers on /stats. checkout and payments-gateway count requests on /metrics.
Standard library only.
"""
import os
import random
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROLE = os.environ["ROLE"]
PORT = int(os.environ.get("PORT", "8080"))
WINDOW = 10  # seconds


def log(level, msg, **fields):
    extra = "".join(f' {k}="{v}"' for k, v in fields.items())
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f'{ts} level={level} service={ROLE} msg="{msg}"{extra}', flush=True)


def by(counter, outcome):
    """'a=3 b=1' for one outcome of a Counter keyed (outcome, name), largest first."""
    items = sorted(((n, c) for (o, n), c in counter.items() if o == outcome), key=lambda x: -x[1])
    return " ".join(f"{n}={c}" for n, c in items) or "none"


class Window:
    """Counts for the current window. The last full window is what /stats shows."""

    def __init__(self):
        self.lock = threading.Lock()
        self.cur, self.last = Counter(), Counter()

    def add(self, outcome, name):
        with self.lock:
            self.cur[(outcome, name)] += 1

    def roll(self):
        with self.lock:
            self.last, self.cur = self.cur, Counter()
            return self.last

    def totals(self, *outcomes):
        """The last full window's count for each outcome, read together."""
        with self.lock:
            return [sum(c for (o, _), c in self.last.items() if o == want) for want in outcomes]


window = Window()
totals, totals_lock = Counter(), threading.Lock()


def count(**labels):
    with totals_lock:
        totals[tuple(sorted(labels.items()))] += 1


def metrics_text():
    lines = ["# HELP http_requests_total Requests answered, by status code.", "# TYPE http_requests_total counter"]
    with totals_lock:
        for key, v in sorted(totals.items()):
            labels = ",".join(f'{k}="{val}"' for k, val in key)
            lines.append(f"http_requests_total{{{labels}}} {v}")
    return "\n".join(lines) + "\n"


def call(url, caller, timeout=2.0):
    """POST to url as caller. Returns the HTTP status, or 0 when nothing answered."""
    req = urllib.request.Request(url, data=b"{}", method="POST", headers={"X-Caller": caller})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp.read()
            return resp.status
    except urllib.error.HTTPError as err:
        err.read()
        return err.code
    except Exception:
        return 0


def paced(rate, fn):
    """Run fn about rate times a second, forever. Falling behind never bursts to catch up.

    Each loop starts at a random point and spaces its calls unevenly, the way real
    clients arrive: loops started together would otherwise fire in lockstep, and the
    rate limiter's budget would refill in the gaps between their bursts.
    """
    interval = 1.0 / rate
    nxt = time.monotonic() + random.uniform(0, interval)
    while True:
        delay = nxt - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        fn()
        nxt = max(nxt, time.monotonic()) + interval * random.uniform(0.5, 1.5)


def every_window(report):
    def loop():
        while True:
            time.sleep(WINDOW)
            report(window.roll())

    threading.Thread(target=loop, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    handle_post = None  # set per role
    stats = None  # set per role

    def log_message(self, *args):  # no access log: the window summaries say it all
        pass

    def reply(self, code, body, headers=None):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/metrics":
            return self.reply(200, metrics_text())
        if self.path == "/stats":
            return self.reply(200, Handler.stats() + "\n")
        if self.path == "/healthz":
            return self.reply(200, "ok\n")
        self.reply(404, "not found\n")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        Handler.handle_post(self)


def serve():
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()


# --- payments-gateway ------------------------------------------------------


def payments():
    limit = float(os.environ.get("LIMIT", "20"))
    lock = threading.Lock()
    bucket = {"tokens": limit, "at": time.monotonic()}

    def take():
        with lock:
            now = time.monotonic()
            bucket["tokens"] = min(limit, bucket["tokens"] + (now - bucket["at"]) * limit)
            bucket["at"] = now
            if bucket["tokens"] >= 1:
                bucket["tokens"] -= 1
                return True
            return False

    def charge(h):
        caller = h.headers.get("X-Caller", "unknown")
        if take():
            code, outcome = 200, "ok"
            h.reply(200, "charged\n")
        else:
            code, outcome = 429, "refused"
            h.reply(429, "processor rate limit reached, retry later\n", {"Retry-After": "1"})
        count(service="payments-gateway", caller=caller, code=str(code))
        window.add(outcome, caller)

    def report(w):
        total = sum(w.values())
        refused = sum(c for (o, _), c in w.items() if o == "refused")
        calls = Counter()
        for (_, name), c in w.items():
            calls[("all", name)] += c
        if refused:
            log("warn", f"rate limit exceeded: refused {refused} of {total} calls in the last {WINDOW}s "
                f"(processor allows {limit:g} calls/s, shared by every caller)",
                calls_by_caller=by(calls, "all"), refused_by_caller=by(w, "refused"))
        else:
            log("info", f"served {total} calls in the last {WINDOW}s (processor allows {limit:g} calls/s)",
                calls_by_caller=by(calls, "all"))

    Handler.handle_post = charge
    Handler.stats = lambda: "ok={} refused={}".format(*window.totals("ok", "refused"))
    every_window(report)
    log("info", f"listening on :{PORT}, processor limit {limit:g} calls/s for the whole account")
    serve()


# --- checkout --------------------------------------------------------------


def checkout():
    url = os.environ.get("PAYMENTS_URL", "http://payments-gateway/charge")

    def place(h):
        status = call(url, "checkout")
        if status == 200:
            code, reason = 200, "ok"
            h.reply(200, "order confirmed\n")
        elif status == 429:
            code, reason = 503, "payments-gateway answered 429 Too Many Requests"
            h.reply(503, "payment provider busy, please try again\n")
        else:
            code, reason = 502, f"payments-gateway answered {status or 'nothing'}"
            h.reply(502, "payment failed\n")
        count(service="checkout", code=str(code))
        window.add("ok" if code == 200 else "failed", reason)

    def report(w):
        total = sum(w.values())
        failed = sum(c for (o, _), c in w.items() if o == "failed")
        if failed:
            log("warn", f"{failed} of {total} orders failed in the last {WINDOW}s", reasons=by(w, "failed"))
        else:
            log("info", f"{total} orders placed in the last {WINDOW}s, none failed")

    Handler.handle_post = place
    Handler.stats = lambda: "ok={} failed={}".format(*window.totals("ok", "failed"))
    every_window(report)
    log("info", f"listening on :{PORT}, charging through {url}")
    serve()


# --- storefront ------------------------------------------------------------


def storefront():
    url = os.environ.get("CHECKOUT_URL", "http://checkout/checkout")
    rate = float(os.environ.get("RATE", "5"))

    def order():
        status = call(url, "storefront")
        window.add("ok" if status == 200 else "failed", str(status or "no answer"))

    def report(w):
        total = sum(w.values())
        failed = sum(c for (o, _), c in w.items() if o == "failed")
        if failed:
            log("warn", f"{failed} of {total} orders failed in the last {WINDOW}s", codes=by(w, "failed"))
        else:
            log("info", f"{total} orders placed in the last {WINDOW}s")

    every_window(report)
    log("info", f"placing {rate:g} orders/s through {url}")
    paced(rate, order)


# --- ledger-reconcile ------------------------------------------------------


def reconcile():
    url = os.environ.get("PAYMENTS_URL", "http://payments-gateway/charge")
    workers = int(os.environ.get("WORKERS", "1"))
    rate = float(os.environ.get("RATE_PER_WORKER", "2"))

    def check():
        status = call(url, "ledger-reconcile")
        window.add("ok" if status == 200 else "retry", "processor")

    def report(w):
        ok = sum(c for (o, _), c in w.items() if o == "ok")
        retry = sum(c for (o, _), c in w.items() if o == "retry")
        log("info", f"reconciled {ok} charges in the last {WINDOW}s, {retry} left for the next pass", workers=workers)

    every_window(report)
    log("info", f"reconciling with {workers} worker(s), {rate:g} calls/s each, through {url}")
    for _ in range(workers - 1):
        threading.Thread(target=paced, args=(rate, check), daemon=True).start()
    paced(rate, check)


{
    "payments-gateway": payments,
    "checkout": checkout,
    "storefront": storefront,
    "ledger-reconcile": reconcile,
}[ROLE]()
