"""Shared helpers for the cloud providers."""

import threading
import time
from datetime import datetime, timezone
from pathlib import Path

_cache: dict = {}
_cache_lock = threading.Lock()


def cached(key: str, ttl: int, producer):
    """Small TTL cache - permission checks and identity lookups are slow and static."""
    with _cache_lock:
        hit = _cache.get(key)
        if hit and time.time() - hit[0] < ttl:
            return hit[1]
    value = producer()
    with _cache_lock:
        _cache[key] = (time.time(), value)
    return value


def forget(key: str) -> None:
    with _cache_lock:
        _cache.pop(key, None)


def now() -> datetime:
    return datetime.now(timezone.utc)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]
