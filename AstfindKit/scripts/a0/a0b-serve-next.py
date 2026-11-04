#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A0-b 第二轮本地 Provider：WeMM-2B / EmbeddingGemma 2 的 OpenAI 兼容端点。

与 a0b-local-server.py 同一协议；模型用 SentenceTransformers 的原生
encode_query（文本）/ encode_document（图片）路径。

WeMM-2B（transformers 5.2 venv，MPS float16）：
  ~/.astfind/a0b/.venv/bin/python AstfindKit/scripts/a0/a0b-serve-next.py \
    --backend weemm2b --model-dir ~/models/weemm-2b \
    --port 8098 --device mps --dtype float16

EmbeddingGemma 2（transformers 5.20 venv，MPS float32）：
  ~/.astfind/a0b/.venv-gemma/bin/python AstfindKit/scripts/a0/a0b-serve-next.py \
    --backend gemma2 --model-dir ~/models/embeddinggemma-2 \
    --port 8097 --device mps --dtype float32
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import torch
from PIL import Image
from sentence_transformers import SentenceTransformer

MODEL = None
BACKEND = "weemm2b"
DEVICE = "mps"
DIM = 0
MODEL_NAME = "local"
MAX_BODY = 32 * 1024 * 1024


def decode_image(data_url: str) -> Image.Image:
    if "," not in data_url:
        raise ValueError("image must be a data: URL")
    payload = base64.b64decode(data_url.split(",", 1)[1], validate=False)
    image = Image.open(io.BytesIO(payload)).convert("RGB")
    # Provider 探针会发 1×1 PNG；统一抬到 ≥64px，避免视觉 processor 的通道歧义。
    if min(image.size) < 64:
        image = image.resize((64, 64), Image.Resampling.BICUBIC)
    return image


def parse_input(value):
    if isinstance(value, str):
        if value.startswith("data:image/"):
            return "image", [decode_image(value)]
        return "text", [value]
    if isinstance(value, list):
        if not value:
            raise ValueError("input list is empty")
        if all(isinstance(item, str) for item in value):
            if any(item.startswith("data:image/") for item in value):
                return "image", [decode_image(item) for item in value]
            return "text", list(value)
        if all(isinstance(item, dict) and "image" in item for item in value):
            return "image", [decode_image(item["image"]) for item in value]
    raise ValueError("unsupported input shape")


def encode(kind: str, items):
    if kind == "text":
        if BACKEND == "weemm2b":
            return MODEL.encode_query(items, normalize_embeddings=True)
        return MODEL.encode(items, prompt_name="SearchQuery", normalize_embeddings=True)
    # 图片不加任务前缀；WeMM 走 encode_document，Gemma 直接 encode。
    if BACKEND == "weemm2b":
        return MODEL.encode_document(items, batch_size=min(8, len(items)), normalize_embeddings=True)
    return MODEL.encode(items, batch_size=min(8, len(items)), normalize_embeddings=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "AstfindLocalEmbed/2.0"

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)

    def send_json(self, status: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"status": "ok", "model": MODEL_NAME, "dim": DIM,
                                 "device": DEVICE, "backend": BACKEND})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/embeddings":
            self.send_json(404, {"error": "not found"})
            return
        began = time.perf_counter()
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BODY:
                raise ValueError(f"bad body length {length}")
            payload = json.loads(self.rfile.read(length))
            kind, items = parse_input(payload.get("input"))
            matrix = encode(kind, items)
            data = [{"object": "embedding", "index": i, "embedding": row.tolist()}
                    for i, row in enumerate(matrix)]
            self.send_json(200, {
                "object": "list", "data": data, "model": payload.get("model") or MODEL_NAME,
                "usage": {"prompt_tokens": 0, "total_tokens": 0},
            })
            print(f"  {kind} n={len(items)} {int((time.perf_counter() - began) * 1000)}ms", flush=True)
        except Exception as exc:  # noqa: BLE001
            self.send_json(400, {"error": f"{type(exc).__name__}: {exc}"})


def main():
    global MODEL, BACKEND, DEVICE, DIM, MODEL_NAME
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", required=True, choices=["weemm2b", "gemma2"])
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--model-name", default=None)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8098)
    parser.add_argument("--device", default="mps", choices=["mps", "cpu"])
    parser.add_argument("--dtype", default="float16", choices=["float16", "float32", "bfloat16"])
    args = parser.parse_args()

    BACKEND = args.backend
    DEVICE = args.device
    MODEL_NAME = args.model_name or args.backend
    dtype = {"float16": torch.float16, "float32": torch.float32, "bfloat16": torch.bfloat16}[args.dtype]
    kwargs = {"model_kwargs": {"torch_dtype": dtype}}
    if args.backend == "weemm2b":
        kwargs["trust_remote_code"] = True
    else:
        kwargs["config_kwargs"] = {"audio_config": None}
    began = time.perf_counter()
    MODEL = SentenceTransformer(args.model_dir, device=args.device, **kwargs)
    DIM = int(MODEL.get_embedding_dimension())
    print(f"loaded {args.model_dir} dim={DIM} backend={BACKEND} device={DEVICE} "
          f"{time.perf_counter() - began:.1f}s", flush=True)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"listening http://{args.host}:{args.port}/v1/embeddings", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
