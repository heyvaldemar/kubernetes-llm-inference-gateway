"""An open-loop probe: one new single-turn request every 1/RATE seconds, sent
on schedule whatever happened to the earlier ones.

The conversation load in loadgen.py is closed-loop: a worker sends its next
request when the last one answers. That is right for measuring how fast
answers come, and wrong for measuring failures, because a failure that comes
back in a millisecond makes the next request come sooner, and the load ends
up hammering whatever fails fastest. Here arrivals do not depend on answers,
as with independent users.

    python3 probe.py --target URL [--rate 50] [--seconds 8]

Prints one JSON line: {"t0", "rate", "results": [[sent unix s, status, s]]},
status 0 when no HTTP answer came (refused, reset, or the timeout).
"""
import argparse
import json
import random
import threading
import time
import urllib.error
import urllib.request


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True)
    ap.add_argument("--model", default="sim/model")
    ap.add_argument("--rate", type=float, default=50)
    ap.add_argument("--seconds", type=float, default=8)
    ap.add_argument("--words", type=int, default=40)
    ap.add_argument("--timeout", type=float, default=30)
    a = ap.parse_args()
    results, lock = [], threading.Lock()

    def one(i):
        # A prompt no replica has seen, so no prefix cache decides where it goes.
        prompt = "probe %d %08x %s" % (i, random.getrandbits(32), "word " * a.words)
        body = json.dumps({"model": a.model, "max_tokens": 1,
                           "messages": [{"role": "user", "content": prompt}]}).encode()
        req = urllib.request.Request(a.target + "/v1/chat/completions", body,
                                     {"Content-Type": "application/json"})
        start = time.time()
        try:
            with urllib.request.urlopen(req, timeout=a.timeout) as r:
                r.read()
                status = r.status
        except urllib.error.HTTPError as e:
            status = e.code
        except Exception:
            status = 0
        with lock:
            results.append([round(start, 3), status, round(time.time() - start, 3)])

    t0 = time.time() + 0.5
    threads = []
    for i in range(int(a.rate * a.seconds)):
        wait = t0 + i / a.rate - time.time()
        if wait > 0:
            time.sleep(wait)
        t = threading.Thread(target=one, args=(i,))
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    print(json.dumps({"t0": t0, "rate": a.rate, "results": sorted(results)}))


if __name__ == "__main__":
    main()
