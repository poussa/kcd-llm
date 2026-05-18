#!/usr/bin/env python3
"""
load-test.py — concurrent LLM load test across workshop groups.

Measures Time-To-First-Token (TTFT), end-to-end latency, and generation
throughput per group to evaluate GPU time-slicing performance.

Usage:
    # Auto-discover gateway IPs from kubectl:
    python3 scripts/load-test.py

    # Explicit namespace list:
    python3 scripts/load-test.py --groups group-1 group-2 group-3

    # Custom load:
    python3 scripts/load-test.py --requests 40 --concurrency 8

Requirements:
    pip install aiohttp
"""

import asyncio
import argparse
import json
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Optional

try:
    import aiohttp
except ImportError:
    sys.exit("ERROR: aiohttp not installed.  Run: pip install aiohttp")

# ── Defaults ─────────────────────────────────────────────────────────────────
DEFAULT_MODEL       = "Qwen/Qwen3-0.6B"
DEFAULT_MAX_TOKENS  = 100
DEFAULT_REQUESTS    = 20   # per group
DEFAULT_CONCURRENCY = 4    # simultaneous requests per group
REQUEST_TIMEOUT     = 120  # seconds

PROMPTS = [
    "What is machine learning? Answer in two sentences.",
    "Explain the difference between a CPU and a GPU.",
    "Write a Python function that computes the Fibonacci sequence.",
    "What are the main causes of climate change?",
    "Describe how HTTPS encryption protects data.",
    "What is Kubernetes and why is it useful?",
    "Explain gradient descent in simple terms.",
    "What is the difference between SQL and NoSQL databases?",
    "How does a transformer model work?",
    "What is the CAP theorem in distributed systems?",
]


# ── Data model ───────────────────────────────────────────────────────────────
@dataclass
class Result:
    group: str
    ttft: Optional[float] = None        # seconds to first token
    latency: Optional[float] = None     # total request time (s)
    tokens: int = 0                     # tokens generated (approx)
    error: Optional[str] = None


# ── Single streaming request ─────────────────────────────────────────────────
async def do_request(
    session: "aiohttp.ClientSession",
    ip: str,
    prompt: str,
    group: str,
    model: str,
    max_tokens: int,
) -> Result:
    r = Result(group=group)
    url = f"http://{ip}/v1/completions"
    payload = {
        "model": model,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "stream": True,
    }
    t0 = time.monotonic()
    try:
        timeout = aiohttp.ClientTimeout(total=REQUEST_TIMEOUT)
        async with session.post(url, json=payload, timeout=timeout) as resp:
            resp.raise_for_status()
            got_first = False
            async for raw_line in resp.content:
                line = raw_line.decode(errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                    text = chunk["choices"][0].get("text", "")
                    if text:
                        if not got_first:
                            r.ttft = time.monotonic() - t0
                            got_first = True
                        # Approx token count: chars / 4 (GPT-style average)
                        r.tokens += max(1, len(text) // 4)
                except (json.JSONDecodeError, KeyError):
                    pass
    except asyncio.TimeoutError:
        r.error = "timeout"
    except Exception as exc:
        r.error = str(exc)
    r.latency = time.monotonic() - t0
    return r


# ── Load test one group ───────────────────────────────────────────────────────
async def test_group(
    ip: str,
    group: str,
    num_requests: int,
    concurrency: int,
    model: str,
    max_tokens: int,
) -> list[Result]:
    prompts = [PROMPTS[i % len(PROMPTS)] for i in range(num_requests)]
    sem = asyncio.Semaphore(concurrency)

    async with aiohttp.ClientSession() as session:
        async def bounded(prompt):
            async with sem:
                return await do_request(session, ip, prompt, group, model, max_tokens)

        return await asyncio.gather(*[bounded(p) for p in prompts])


# ── kubectl IP discovery ──────────────────────────────────────────────────────
def get_gateway_ips(namespaces: list[str]) -> dict[str, str]:
    ips = {}
    for ns in namespaces:
        try:
            out = subprocess.check_output(
                [
                    "kubectl", "get", "gateway", "llm-d-inference-gateway",
                    "-n", ns,
                    "-o", "jsonpath={.status.addresses[0].value}",
                ],
                stderr=subprocess.DEVNULL,
                timeout=10,
                text=True,
            ).strip()
            if out:
                ips[ns] = out
            else:
                print(f"  WARNING: no IP yet for {ns} — skipping")
        except Exception as exc:
            print(f"  WARNING: could not query {ns}: {exc} — skipping")
    return ips


# ── Stats helpers ─────────────────────────────────────────────────────────────
def pct(data: list[float], p: float) -> float:
    if not data:
        return float("nan")
    s = sorted(data)
    idx = max(0, int(len(s) * p) - 1)
    return s[idx]


# ── Report ─────────────────────────────────────────────────────────────────────
def print_report(all_results: dict[str, list[Result]], wall_time: float) -> None:
    cols = ["GROUP", "REQ", "ERR", "TTFT p50", "TTFT p95", "LAT p50", "LAT p95", "TOK/S"]
    fmt  = "{:<12} {:>4} {:>4} {:>9} {:>9} {:>9} {:>9} {:>8}"
    sep  = "─" * 78

    print("\n" + sep)
    print(fmt.format(*cols))
    print(sep)

    all_ttfts, all_lats = [], []
    for group, results in sorted(all_results.items()):
        errs   = [r for r in results if r.error]
        ok     = [r for r in results if not r.error]
        ttfts  = [r.ttft    for r in ok if r.ttft    is not None]
        lats   = [r.latency for r in ok if r.latency is not None]
        tokens = sum(r.tokens for r in ok)
        # Throughput: tokens generated / wall time of the group run
        span   = max(lats) if lats else 1
        tps    = tokens / span if span else 0

        all_ttfts += ttfts
        all_lats  += lats

        def f(v): return f"{v:.2f}s" if v == v else "  n/a "

        print(fmt.format(
            group,
            len(results),
            len(errs),
            f(pct(ttfts, 0.50)),
            f(pct(ttfts, 0.95)),
            f(pct(lats,  0.50)),
            f(pct(lats,  0.95)),
            f"{tps:.1f}",
        ))

    print(sep)
    # Aggregate
    total_req    = sum(len(v) for v in all_results.values())
    total_err    = sum(len([r for r in v if r.error]) for v in all_results.values())
    total_tokens = sum(r.tokens for v in all_results.values() for r in v if not r.error)
    print(fmt.format(
        "ALL GROUPS",
        total_req,
        total_err,
        f"{pct(all_ttfts, 0.50):.2f}s",
        f"{pct(all_ttfts, 0.95):.2f}s",
        f"{pct(all_lats,  0.50):.2f}s",
        f"{pct(all_lats,  0.95):.2f}s",
        f"{total_tokens / wall_time:.1f}",
    ))
    print(sep)
    print("TTFT = Time To First Token  |  LAT = end-to-end latency  |  TOK/S = tokens/sec")
    print(f"Total wall time: {wall_time:.1f}s  |  Total errors: {total_err}/{total_req}")
    print()


# ── Main ──────────────────────────────────────────────────────────────────────
async def main(args: argparse.Namespace) -> None:
    # Resolve groups
    groups = args.groups or [f"group-{i}" for i in range(1, args.num_groups + 1)]

    print(f"Discovering gateway IPs for {len(groups)} group(s)…")
    if args.ips:
        # Manual override: --ips group-1=1.2.3.4 group-2=5.6.7.8
        ip_map = {}
        for entry in args.ips:
            g, ip = entry.split("=", 1)
            ip_map[g] = ip
    else:
        ip_map = get_gateway_ips(groups)

    if not ip_map:
        sys.exit("ERROR: no reachable groups found.")

    print(f"Testing {len(ip_map)} group(s): {', '.join(sorted(ip_map))}")
    print(f"  {args.requests} requests × {args.concurrency} concurrent / group  |  model: {args.model}")
    print()

    t0 = time.monotonic()
    tasks = {
        group: asyncio.create_task(
            test_group(ip, group, args.requests, args.concurrency, args.model, args.max_tokens)
        )
        for group, ip in ip_map.items()
    }
    all_results = {}
    for group, task in tasks.items():
        all_results[group] = await task
        ok  = len([r for r in all_results[group] if not r.error])
        err = len([r for r in all_results[group] if r.error])
        print(f"  {group}: {ok} ok, {err} errors")

    wall = time.monotonic() - t0
    print_report(all_results, wall)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--groups",      nargs="+", metavar="NS",
                   help="Namespaces to test (default: group-1 … group-N)")
    p.add_argument("--num-groups",  type=int, default=4, metavar="N",
                   help="Number of groups when --groups is not set (default: 8)")
    p.add_argument("--ips",         nargs="+", metavar="GROUP=IP",
                   help="Manual IP override, e.g. group-1=34.90.1.2")
    p.add_argument("--requests",    type=int, default=DEFAULT_REQUESTS,
                   help=f"Requests per group (default: {DEFAULT_REQUESTS})")
    p.add_argument("--concurrency", type=int, default=DEFAULT_CONCURRENCY,
                   help=f"Concurrent requests per group (default: {DEFAULT_CONCURRENCY})")
    p.add_argument("--model",       default=DEFAULT_MODEL,
                   help=f"Model name (default: {DEFAULT_MODEL})")
    p.add_argument("--max-tokens",  type=int, default=DEFAULT_MAX_TOKENS,
                   help=f"Max tokens per response (default: {DEFAULT_MAX_TOKENS})")
    return p.parse_args()


if __name__ == "__main__":
    asyncio.run(main(parse_args()))
