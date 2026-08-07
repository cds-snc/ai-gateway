#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone


def load_models(models_path):
    with open(models_path, "r", encoding="utf-8") as f:
        payload = json.load(f)

    data = payload.get("data")
    if not isinstance(data, list):
        raise SystemExit("Invalid /models response: expected object with list at key 'data'.")
    return data


def command_count(args):
    data = load_models(args.models_file)
    print(len(data))


def command_write_empty(args):
    summary = {
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "base_url": args.base_url,
        "prompt": args.prompt,
        "max_tokens": args.max_tokens,
        "timeout_seconds": args.timeout,
        "totals": {
            "models_discovered": 0,
            "models_tested": 0,
            "passed": 0,
            "failed": 0,
            "discovered_by_kind": {
                "chat": 0,
                "embedding": 0,
                "rerank": 0,
            },
            "tested_by_kind": {
                "chat": 0,
                "embedding": 0,
                "rerank": 0,
            },
            "passed_by_kind": {
                "chat": 0,
                "embedding": 0,
                "rerank": 0,
            },
            "failed_by_kind": {
                "chat": 0,
                "embedding": 0,
                "rerank": 0,
            },
        },
        "results": [],
    }

    with open(args.summary_file, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    with open(args.failures_file, "w", encoding="utf-8") as f:
        json.dump([], f, indent=2)


def _text_values(value):
    if isinstance(value, str):
        return [value.lower()]
    if isinstance(value, list):
        out = []
        for item in value:
            if isinstance(item, str):
                out.append(item.lower())
            elif isinstance(item, dict):
                for nested in item.values():
                    out.extend(_text_values(nested))
        return out
    if isinstance(value, dict):
        out = []
        for nested in value.values():
            out.extend(_text_values(nested))
        return out
    return []


def infer_model_test_kind(model):
    model_id = str(model.get("id", "")).lower()

    rerank_markers = (
        "rerank",
        "re-rank",
        "rank",
        "cross-encoder",
    )
    embed_markers = (
        "embed",
        "embedding",
        "vector",
    )

    metadata_text = []
    for key in (
        "mode",
        "type",
        "model_type",
        "capabilities",
        "supported_generation_methods",
        "description",
        "input_type",
        "output_type",
    ):
        metadata_text.extend(_text_values(model.get(key)))

    joined_metadata = " ".join(metadata_text)

    if any(marker in model_id for marker in rerank_markers) or any(
        marker in joined_metadata for marker in rerank_markers
    ):
        return "rerank"

    if any(marker in model_id for marker in embed_markers) or any(
        marker in joined_metadata for marker in embed_markers
    ):
        return "embedding"

    return "chat"


def command_run(args):
    models_data = load_models(args.models_file)

    model_entries = []
    seen_model_ids = set()
    for model in models_data:
        if not isinstance(model, dict):
            continue
        model_id = model.get("id")
        if isinstance(model_id, str) and model_id not in seen_model_ids:
            seen_model_ids.add(model_id)
            model_entries.append(
                {
                    "id": model_id,
                    "test_kind": infer_model_test_kind(model),
                }
            )

    results = []
    failures = []

    rerank_documents = [
        "Canada has ten provinces and three territories.",
        "Maple leaves are a national symbol of Canada.",
        "The Sahara is the largest hot desert in the world.",
    ]

    for idx, model_entry in enumerate(model_entries, start=1):
        model_id = model_entry["id"]
        test_kind = model_entry["test_kind"]

        if test_kind == "embedding":
            endpoint = "/v1/embeddings"
            request_payload = {
                "model": model_id,
                "input": [args.prompt],
            }
        elif test_kind == "rerank":
            endpoint = "/v1/rerank"
            request_payload = {
                "model": model_id,
                "query": args.prompt,
                "documents": rerank_documents,
                "top_n": 1,
            }
        else:
            endpoint = "/v1/chat/completions"
            request_payload = {
                "model": model_id,
                "messages": [{"role": "user", "content": args.prompt}],
                "max_tokens": args.max_tokens,
            }

        body = json.dumps(request_payload)
        cmd = [
            "curl",
            "-sS",
            "-m",
            str(args.timeout),
            "-o",
            "-",
            "-w",
            "\\n__HTTP_CODE__:%{http_code}",
            "-X",
            "POST",
            f"{args.base_url}{endpoint}",
            "-H",
            f"Authorization: Bearer {args.api_key}",
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            body,
        ]

        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        except Exception as exc:
            result = {
                "model": model_id,
                "test_kind": test_kind,
                "endpoint": endpoint,
                "status": "error",
                "http_status": None,
                "success": False,
                "request": request_payload,
                "error": {
                    "type": "script_exception",
                    "message": str(exc),
                },
            }
            results.append(result)
            failures.append(result)
            if args.verbose:
                print(
                    f"[{idx}/{len(model_entries)}] FAIL  {model_id} kind={test_kind} (script exception)",
                    file=sys.stderr,
                )
            continue

        stdout = proc.stdout or ""
        stderr = proc.stderr or ""

        marker = "\n__HTTP_CODE__:"
        if marker in stdout:
            response_body, http_code_str = stdout.rsplit(marker, 1)
            http_code_str = http_code_str.strip()
        else:
            response_body = stdout
            http_code_str = "000"

        try:
            http_code = int(http_code_str)
        except ValueError:
            http_code = 0

        parsed_response = None
        response_text = response_body.strip()
        if response_text:
            try:
                parsed_response = json.loads(response_text)
            except json.JSONDecodeError:
                parsed_response = None

        success = False
        error_obj = None

        if proc.returncode != 0:
            error_obj = {
                "type": "curl_error",
                "message": stderr.strip() or f"curl exited with {proc.returncode}",
                "return_code": proc.returncode,
            }
        elif 200 <= http_code < 300:
            if isinstance(parsed_response, dict) and parsed_response.get("error"):
                error_obj = {
                    "type": "api_error_in_success_response",
                    "message": str(parsed_response.get("error")),
                }
            else:
                success = True
        else:
            api_error = None
            if isinstance(parsed_response, dict):
                api_error = parsed_response.get("error")
            if api_error is not None:
                error_obj = {
                    "type": "api_error",
                    "message": str(api_error),
                }
            else:
                error_obj = {
                    "type": "http_error",
                    "message": f"HTTP {http_code}",
                }

        result = {
            "model": model_id,
            "test_kind": test_kind,
            "endpoint": endpoint,
            "status": "ok" if success else "error",
            "http_status": http_code if http_code != 0 else None,
            "success": success,
            "request": request_payload,
        }

        if success:
            if isinstance(parsed_response, dict):
                if test_kind == "embedding":
                    result["response_excerpt"] = {
                        "model": parsed_response.get("model"),
                        "data_count": len(parsed_response.get("data", []))
                        if isinstance(parsed_response.get("data"), list)
                        else None,
                    }
                elif test_kind == "rerank":
                    result["response_excerpt"] = {
                        "model": parsed_response.get("model"),
                        "results_count": len(parsed_response.get("results", []))
                        if isinstance(parsed_response.get("results"), list)
                        else None,
                    }
                else:
                    result["response_excerpt"] = {
                        "id": parsed_response.get("id"),
                        "model": parsed_response.get("model"),
                        "choices_count": len(parsed_response.get("choices", []))
                        if isinstance(parsed_response.get("choices"), list)
                        else None,
                    }
        else:
            result["error"] = error_obj
            if parsed_response is not None:
                result["response_body"] = parsed_response
            elif response_text:
                result["response_body_raw"] = response_text
            if stderr.strip():
                result["stderr"] = stderr.strip()
            failures.append(result)

        results.append(result)

        if args.verbose:
            status_text = "PASS" if success else "FAIL"
            http_text = http_code if http_code else "n/a"
            print(
                f"[{idx}/{len(model_entries)}] {status_text:<5} {model_id} kind={test_kind} (http={http_text})",
                file=sys.stderr,
            )

    passed = sum(1 for item in results if item.get("success"))
    failed = len(results) - passed

    discovered_by_kind = {"chat": 0, "embedding": 0, "rerank": 0}
    for model_entry in model_entries:
        kind = model_entry["test_kind"]
        discovered_by_kind[kind] = discovered_by_kind.get(kind, 0) + 1

    tested_by_kind = {"chat": 0, "embedding": 0, "rerank": 0}
    passed_by_kind = {"chat": 0, "embedding": 0, "rerank": 0}
    for item in results:
        kind = item.get("test_kind", "chat")
        tested_by_kind[kind] = tested_by_kind.get(kind, 0) + 1
        if item.get("success"):
            passed_by_kind[kind] = passed_by_kind.get(kind, 0) + 1

    failed_by_kind = {
        kind: tested_by_kind.get(kind, 0) - passed_by_kind.get(kind, 0)
        for kind in tested_by_kind
    }

    summary = {
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "base_url": args.base_url,
        "prompt": args.prompt,
        "max_tokens": args.max_tokens,
        "timeout_seconds": args.timeout,
        "totals": {
            "models_discovered": len(model_entries),
            "models_tested": len(results),
            "passed": passed,
            "failed": failed,
            "discovered_by_kind": discovered_by_kind,
            "tested_by_kind": tested_by_kind,
            "passed_by_kind": passed_by_kind,
            "failed_by_kind": failed_by_kind,
        },
        "results": results,
    }

    with open(args.summary_file, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    with open(args.failures_file, "w", encoding="utf-8") as f:
        json.dump(failures, f, indent=2)

    print(f"PASS: {passed}")
    print(f"FAIL: {failed}")


def build_parser():
    parser = argparse.ArgumentParser(description="Helpers for test_models_for_key.sh")
    subparsers = parser.add_subparsers(dest="command", required=True)

    parser_count = subparsers.add_parser("count")
    parser_count.add_argument("--models-file", required=True)
    parser_count.set_defaults(func=command_count)

    parser_empty = subparsers.add_parser("write-empty")
    parser_empty.add_argument("--summary-file", required=True)
    parser_empty.add_argument("--failures-file", required=True)
    parser_empty.add_argument("--base-url", required=True)
    parser_empty.add_argument("--prompt", required=True)
    parser_empty.add_argument("--max-tokens", required=True, type=int)
    parser_empty.add_argument("--timeout", required=True, type=int)
    parser_empty.set_defaults(func=command_write_empty)

    parser_run = subparsers.add_parser("run")
    parser_run.add_argument("--models-file", required=True)
    parser_run.add_argument("--base-url", required=True)
    parser_run.add_argument("--api-key", required=True)
    parser_run.add_argument("--prompt", required=True)
    parser_run.add_argument("--max-tokens", required=True, type=int)
    parser_run.add_argument("--timeout", required=True, type=int)
    parser_run.add_argument("--summary-file", required=True)
    parser_run.add_argument("--failures-file", required=True)
    parser_run.add_argument("--verbose", action="store_true")
    parser_run.set_defaults(func=command_run)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
