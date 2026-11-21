"""Quota counters for one local process or shared Redis deployments."""

import os, time, threading, hashlib
import redis

cache = (
    redis.Redis.from_url(os.environ["REDIS_URL"], socket_timeout=2)
    if os.getenv("REDIS_URL")
    else None
)
counts = {}
lock = threading.Lock()


def allowed(identity, limit, seconds):
    now = int(time.time())
    k = (
        "cv:"
        + hashlib.sha256(identity.encode()).hexdigest()
        + ":"
        + str(now // seconds)
    )
    if cache:
        with cache.pipeline(transaction=True) as pipe:
            n, _ = pipe.incr(k).expire(k, seconds + 1).execute()
        return n <= limit
    with lock:
        if len(counts) > 5000:
            for key in [key for key, (_, end) in counts.items() if end <= now]:
                del counts[key]
        value, end = counts.get(k, (0, now + seconds))
        counts[k] = (value + 1, end)
        return value < limit
