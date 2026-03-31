"""
Comprehensive test script for the AI Inference Platform demo.
Tests: health check, models list, chat completion (blocking), chat completion (streaming).

Usage:
    python test/test_api.py --base-url http://$MINIKUBE_IP:30080 --api-key demo-api-key-12345
"""

import argparse
import json
import sys
import time
from typing import Optional

import httpx
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich import print as rprint

console = Console()

def print_section(title: str):
    console.rule(f"[bold cyan]{title}[/bold cyan]")

def print_pass(test_name: str, detail: str = ""):
    msg = f"[bold green]PASS[/bold green]  {test_name}"
    if detail:
        msg += f" — {detail}"
    console.print(msg)

def print_fail(test_name: str, detail: str = ""):
    msg = f"[bold red]FAIL[/bold red]  {test_name}"
    if detail:
        msg += f" — {detail}"
    console.print(msg)

def test_health_no_auth(base_url: str) -> bool:
    print_section("Test 1: Health Check (no auth required)")
    try:
        with httpx.Client(timeout=10.0) as client:
            resp = client.get(f"{base_url}/health")
            data = resp.json()
            console.print_json(json.dumps(data))
            if resp.status_code == 200 and data.get("gateway") == "ok":
                print_pass("Health check", f"gateway=ok, backend_vllm={data.get('backend_vllm')}")
                return True
            else:
                print_fail("Health check", f"status={resp.status_code}, body={data}")
                return False
    except Exception as exc:
        print_fail("Health check", str(exc))
        return False

def test_auth_rejection(base_url: str) -> bool:
    print_section("Test 2: Auth Rejection (no API key)")
    try:
        with httpx.Client(timeout=10.0) as client:
            resp = client.get(f"{base_url}/v1/models")
            if resp.status_code in (401, 403):
                print_pass("Auth rejection", f"status={resp.status_code} (correct)")
                return True
            else:
                print_fail("Auth rejection", f"Expected 401/403, got {resp.status_code}")
                return False
    except Exception as exc:
        print_fail("Auth rejection", str(exc))
        return False

def test_list_models(base_url: str, api_key: str) -> bool:
    print_section("Test 3: List Models")
    try:
        with httpx.Client(timeout=15.0) as client:
            resp = client.get(
                f"{base_url}/v1/models",
                headers={"X-API-Key": api_key},
            )
            resp.raise_for_status()
            data = resp.json()
            console.print_json(json.dumps(data))
            models = data.get("data", [])
            if models:
                model_ids = [m["id"] for m in models]
                print_pass("List models", f"Models: {model_ids}")
                return True
            else:
                print_fail("List models", "Empty model list — vLLM may still be loading")
                return False
    except Exception as exc:
        print_fail("List models", str(exc))
        return False

def test_chat_completion_blocking(base_url: str, api_key: str, model: str = "tinyllama") -> bool:
    print_section("Test 4: Chat Completion (Blocking / Non-Streaming)")
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are a helpful assistant. Be concise."},
            {"role": "user", "content": "What is Kubernetes in one sentence?"},
        ],
        "max_tokens": 100,
        "temperature": 0.7,
        "stream": False,
    }
    try:
        start = time.time()
        with httpx.Client(timeout=120.0) as client:
            resp = client.post(
                f"{base_url}/v1/chat/completions",
                json=payload,
                headers={"X-API-Key": api_key},
            )
            resp.raise_for_status()
            elapsed = time.time() - start
            data = resp.json()

            content = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})

            console.print(f"\n[bold]Response:[/bold] {content}\n")
            console.print(f"[dim]Elapsed: {elapsed:.2f}s | Tokens: prompt={usage.get('prompt_tokens','?')}, completion={usage.get('completion_tokens','?')}[/dim]")

            print_pass("Blocking chat completion", f"Got {len(content)} chars in {elapsed:.2f}s")
            return True
    except Exception as exc:
        print_fail("Blocking chat completion", str(exc))
        return False

def test_chat_completion_streaming(base_url: str, api_key: str, model: str = "tinyllama") -> bool:
    print_section("Test 5: Chat Completion (Streaming SSE)")
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Count from 1 to 5 and explain what each number means in computing."},
        ],
        "max_tokens": 200,
        "temperature": 0.8,
        "stream": True,
    }

    collected_tokens = []
    start = time.time()
    chunk_count = 0

    try:
        console.print("[bold]Streaming tokens:[/bold] ", end="")
        with httpx.Client(timeout=None) as client:
            with client.stream(
                "POST",
                f"{base_url}/v1/chat/completions",
                json=payload,
                headers={"X-API-Key": api_key},
                timeout=120.0,
            ) as resp:
                resp.raise_for_status()
                buffer = ""
                for raw_chunk in resp.iter_bytes(chunk_size=1024):
                    chunk_text = raw_chunk.decode("utf-8", errors="replace")
                    buffer += chunk_text

                    while "\n" in buffer:
                        line, buffer = buffer.split("\n", 1)
                        line = line.strip()
                        if not line:
                            continue
                        if line.startswith("data: "):
                            data_str = line[6:]
                            if data_str == "[DONE]":
                                console.print()
                                break
                            try:
                                data = json.loads(data_str)
                                delta = data["choices"][0].get("delta", {})
                                token = delta.get("content", "")
                                if token:
                                    console.print(token, end="", highlight=False)
                                    collected_tokens.append(token)
                                    chunk_count += 1
                            except json.JSONDecodeError:
                                pass

        elapsed = time.time() - start
        full_response = "".join(collected_tokens)
        tokens_per_sec = len(collected_tokens) / elapsed if elapsed > 0 else 0

        console.print(f"\n[dim]Elapsed: {elapsed:.2f}s | Tokens streamed: {len(collected_tokens)} | Rate: {tokens_per_sec:.1f} tok/s[/dim]")
        print_pass("Streaming chat completion", f"{len(collected_tokens)} tokens in {elapsed:.2f}s ({tokens_per_sec:.1f} tok/s)")
        return True

    except Exception as exc:
        console.print()
        print_fail("Streaming chat completion", str(exc))
        return False

def test_wrong_api_key(base_url: str) -> bool:
    print_section("Test 6: Wrong API Key")
    try:
        with httpx.Client(timeout=10.0) as client:
            resp = client.post(
                f"{base_url}/v1/chat/completions",
                json={"model": "tinyllama", "messages": []},
                headers={"X-API-Key": "wrong-key-9999"},
            )
            if resp.status_code == 403:
                print_pass("Wrong API key rejected", "status=403 (correct)")
                return True
            else:
                print_fail("Wrong API key", f"Expected 403, got {resp.status_code}")
                return False
    except Exception as exc:
        print_fail("Wrong API key", str(exc))
        return False

def main():
    parser = argparse.ArgumentParser(description="AI Platform Demo — Test Suite")
    parser.add_argument("--base-url", default="http://192.168.49.2:30080", help="Base URL of the AI gateway")
    parser.add_argument("--api-key", default="demo-api-key-12345", help="API key for authentication")
    parser.add_argument("--model", default="tinyllama", help="Model name to use")
    args = parser.parse_args()

    console.print(Panel.fit(
        f"[bold]AI Platform Demo — Test Suite[/bold]\n"
        f"Base URL: {args.base_url}\n"
        f"API Key:  {args.api_key}\n"
        f"Model:    {args.model}",
        title="Configuration",
        border_style="cyan",
    ))

    results = {}
    results["health"] = test_health_no_auth(args.base_url)
    results["auth_rejection"] = test_auth_rejection(args.base_url)
    results["wrong_key"] = test_wrong_api_key(args.base_url)
    results["list_models"] = test_list_models(args.base_url, args.api_key)
    results["blocking"] = test_chat_completion_blocking(args.base_url, args.api_key, args.model)
    results["streaming"] = test_chat_completion_streaming(args.base_url, args.api_key, args.model)

    print_section("Summary")
    table = Table(title="Test Results", show_header=True, header_style="bold magenta")
    table.add_column("Test", style="cyan")
    table.add_column("Result", justify="center")

    labels = {
        "health": "Health check (no auth)",
        "auth_rejection": "Auth rejection (no key)",
        "wrong_key": "Wrong API key rejected",
        "list_models": "List models",
        "blocking": "Chat completion (blocking)",
        "streaming": "Chat completion (SSE streaming)",
    }

    all_passed = True
    for key, label in labels.items():
        passed = results.get(key, False)
        if not passed:
            all_passed = False
        status = "[bold green]PASS[/bold green]" if passed else "[bold red]FAIL[/bold red]"
        table.add_row(label, status)

    console.print(table)

    if all_passed:
        console.print("\n[bold green]All tests passed![/bold green] The platform is working correctly.")
        sys.exit(0)
    else:
        failed = [labels[k] for k, v in results.items() if not v]
        console.print(f"\n[bold red]Failed tests:[/bold red] {', '.join(failed)}")
        sys.exit(1)

if __name__ == "__main__":
    main()
