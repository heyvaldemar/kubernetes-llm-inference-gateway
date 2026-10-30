#!/usr/bin/env python3
"""Multi-turn chat load against an OpenAI-compatible endpoint, timed per request.

    loadgen.py --target http://router-epp --label router [--sessions 32 ...]

Each session is one conversation: a long system prompt of its own, then
--turns user messages, each sent with the whole history so far, the way a
chat client or an agent's tool loop resends its context. Sessions run
--concurrency at a time; the turns of one session run in order. Every
request streams, so the time to the first content token (TTFT) is measured
where a user waits for it, and the last line printed is a JSON summary.

The prompts are made from --seed: the same seed gives the same words, so two
runs against two routes see the same conversations; a different seed gives
conversations no cache has seen. Standard library only.
"""
import argparse
import http.client
import json
import random
import statistics
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

T0 = 0.0
START_MS = 0
WORDS = ("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar "
         "papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu cluster node pod policy "
         "image digest replica request token cache prefix gateway router scheduler latency budget").split()


def words(rng, n):
    return " ".join(rng.choice(WORDS) for _ in range(n))


def percentile(values, p):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def stream_chat(url, model, messages, max_tokens, timeout):
    """One streamed chat completion: (ttft_s, total_s, text, status)."""
    u = urllib.parse.urlsplit(url)
    conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=timeout)
    body = json.dumps({"model": model, "messages": messages, "max_tokens": max_tokens,
                       "stream": True, "temperature": 0}).encode()
    t0 = time.monotonic()
    try:
        conn.request("POST", "/v1/chat/completions", body=body, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        if resp.status != 200:
            resp.read()
            return None, time.monotonic() - t0, "", resp.status
        ttft, parts, done = None, [], False
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                done = True
                break
            try:
                delta = json.loads(data)["choices"][0].get("delta", {}).get("content") or ""
            except (ValueError, KeyError, IndexError):
                continue
            if delta and ttft is None:
                ttft = time.monotonic() - t0
            parts.append(delta)
        # A stream that ends without [DONE] was cut mid-answer: the user saw a
        # partial reply, so it is a failure, reported as status -1.
        return ttft, time.monotonic() - t0, "".join(parts), 200 if done else -1
    except (OSError, http.client.HTTPException):
        return None, time.monotonic() - t0, "", 0
    finally:
        conn.close()


def run_session(args, sid, results, lock):
    rng = random.Random(f"{args.seed}/{sid}")
    history = [{"role": "system", "content": f"Session {sid}. " + words(rng, args.system_words)}]
    for turn in range(args.turns):
        history.append({"role": "user", "content": words(rng, args.turn_words)})
        ttft, total, text, status = stream_chat(args.target, args.model, history, args.max_tokens, args.timeout)
        with lock:
            results.append({"session": sid, "turn": turn, "ttft": ttft, "total": total, "status": status,
                            "at": time.monotonic() - T0})
        if status != 200:
            return
        history.append({"role": "assistant", "content": text})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True)
    ap.add_argument("--label", default="run")
    ap.add_argument("--model", default="sim/model")
    ap.add_argument("--sessions", type=int, default=32)
    ap.add_argument("--turns", type=int, default=6)
    ap.add_argument("--concurrency", type=int, default=16)
    ap.add_argument("--system-words", type=int, default=600)
    ap.add_argument("--turn-words", type=int, default=40)
    ap.add_argument("--max-tokens", type=int, default=24)
    ap.add_argument("--seed", default="1")
    ap.add_argument("--timeout", type=float, default=120)
    args = ap.parse_args()

    global T0
    results, lock = [], threading.Lock()
    global START_MS
    t0 = T0 = time.monotonic()
    START_MS = int(time.time() * 1000)
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        for sid in range(args.sessions):
            pool.submit(run_session, args, sid, results, lock)
    wall = time.monotonic() - t0

    ok = [r for r in results if r["status"] == 200 and r["ttft"] is not None]
    later = [r["ttft"] for r in ok if r["turn"] > 0]
    summary = {
        "label": args.label, "seed": args.seed, "start_unix_ms": START_MS, "requests": len(results), "ok": len(ok),
        "failed": len(results) - len(ok), "wall_s": round(wall, 2),
        "ttft_ms": {p: round(1000 * percentile([r["ttft"] for r in ok], p), 1) for p in (50, 90, 99)} if ok else None,
        # Turns after the first are the ones a prefix cache can help: the
        # first turn of a session has nothing cached anywhere.
        "ttft_later_turns_ms": {p: round(1000 * percentile(later, p), 1) for p in (50, 90, 99)} if later else None,
        "total_ms_p50": round(1000 * statistics.median([r["total"] for r in ok]), 1) if ok else None,
        # Each failure with when it happened (seconds from the start) and what
        # it was: an HTTP status, 0 for a connection that broke before any
        # answer, -1 for a stream cut mid-answer. A session stops at its first failure, as a client would.
        "failures": sorted(([round(r["at"], 2), r["status"], r["turn"]] for r in results
                            if not (r["status"] == 200 and r["ttft"] is not None)), key=lambda f: f[0]),
    }
    print(json.dumps(summary))
    return 0 if summary["failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
