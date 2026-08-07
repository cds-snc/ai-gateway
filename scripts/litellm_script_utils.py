#!/usr/bin/env python3

import argparse
import json
import pathlib
import re


def cmd_first_model_alias(args):
    text = pathlib.Path(args.config_path).read_text(encoding="utf-8")
    match = re.search(r"^\s*-\s*model_name:\s*['\"]?([^'\"\s#]+)['\"]?", text, re.MULTILINE)
    if not match:
        raise SystemExit("Could not find a model_name entry in config.yaml")
    print(match.group(1))


def cmd_chat_payload(args):
    payload = {
        "model": args.model_alias,
        "messages": [
            {
                "role": "user",
                "content": args.prompt,
            }
        ],
        "max_tokens": args.max_tokens,
    }
    print(json.dumps(payload))


def cmd_key_generate_payload(args):
    payload = {
        "models": [args.model_alias],
        "metadata": {
            "provisioned_by": "scripts/create_virtual_key.sh",
        },
    }

    if args.duration:
        payload["duration"] = args.duration

    if args.key_alias:
        payload["key_alias"] = args.key_alias

    print(json.dumps(payload))


def cmd_print_generated_key(args):
    response = json.loads(pathlib.Path(args.response_file).read_text(encoding="utf-8"))
    key_value = response.get("key") or response.get("token")

    if not key_value:
        raise SystemExit(f"Success response did not include a key field: {response}")

    print(f"Generated virtual key for model alias: {args.model_alias}")
    print(f"LiteLLM base URL: {args.base_url}")
    print(f"Virtual key: {key_value}")

    expires = response.get("expires") or response.get("expiration")
    if expires:
        print(f"Expires: {expires}")


def build_parser():
    parser = argparse.ArgumentParser(description="Utilities for LiteLLM shell scripts")
    subparsers = parser.add_subparsers(dest="command", required=True)

    parser_alias = subparsers.add_parser("first-model-alias")
    parser_alias.add_argument("--config-path", required=True)
    parser_alias.set_defaults(func=cmd_first_model_alias)

    parser_chat = subparsers.add_parser("chat-payload")
    parser_chat.add_argument("--prompt", required=True)
    parser_chat.add_argument("--model-alias", required=True)
    parser_chat.add_argument("--max-tokens", required=True, type=int)
    parser_chat.set_defaults(func=cmd_chat_payload)

    parser_key = subparsers.add_parser("key-generate-payload")
    parser_key.add_argument("--model-alias", required=True)
    parser_key.add_argument("--duration")
    parser_key.add_argument("--key-alias")
    parser_key.set_defaults(func=cmd_key_generate_payload)

    parser_print = subparsers.add_parser("print-generated-key")
    parser_print.add_argument("--response-file", required=True)
    parser_print.add_argument("--model-alias", required=True)
    parser_print.add_argument("--base-url", required=True)
    parser_print.set_defaults(func=cmd_print_generated_key)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
