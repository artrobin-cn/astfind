#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A0-b 本地 Provider：把 Chinese-CLIP 包成 OpenAI 兼容 /v1/embeddings 端点。

用途：在不改产品默认 Provider 的前提下，用 Astfind 的 Provider 体系实测本地模型
（零外发、局域网/本机 HTTP）。输入形状与 WeMM 相同：
  text:  {"model":"...","input":"查询文本"}
  image: {"model":"...","input":[{"image":"data:image/png;base64,..."}]}
  batch: {"model":"...","input":[{"image":...},{"image":...}]}

启动（需 a0b venv）：
  ~/.astfind/a0b/.venv/bin/python AstfindKit/scripts/a0/a0b-local-server.py \
      --model-dir ~/.astfind/a0b/chinese-clip-vit-b16 --port 8099
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import torch
from PIL import Image
from transformers import ChineseCLIPModel, ChineseCLIPProcessor

MODEL = None
PROCESSOR = None
DEVICE = "cpu"
MODEL_NAME = "chinese-clip-local"
DIM = 0
MAX_BODY = 32 * 1024 * 1024


def decode_image(data_url: str) -> Image.Image:
    if "," not in data_url:
        raise ValueError("image must be a data: URL")
    payload = base64.b64decode(data_url.split(",", 1)[1], validate=False)
    return Image.open(io.BytesIO(payload)).convert("RGB")


def embed_texts(texts: list[str]) -> np.ndarray:
    inputs = PROCESSOR(text=texts, return_tensors="pt", padding=True, truncation=True, max_length=64)
    inputs = {k: v.to(DEVICE) for k, v in inputs.items()}
    with torch.inference_mode():
        features = MODEL.get_text_features(**inputs)
        features = features / features.norm(dim=-1, keepdim=True)
    return features.detach().cpu().numpy().astype(np.float32)


def embed_images(images: list[Image.Image]) -> np.ndarray:
    # 探针会发 1×1 PNG；PIL 通道维歧义会让 processor 报错，统一抬到 ≥64px。
    images = [img.resize((64, 64), Image.Resampling.BICUBIC) if min(img.size) < 64 else img
              for img in images]
    inputs = PROCESSOR(images=images, return_tensors="pt")
    inputs = {k: v.to(DEVICE) for k, v in inputs.items()}
    with torch.inference_mode():
        features = MODEL.get_image_features(**inputs)
        features = features / features.norm(dim=-1, keepdim=True)
    return features.detach().cpu().numpy().astype(np.float32)


def parse_input(value):
    """返回 ('text', [str]) 或 ('image', [PIL.Image])。"""
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


class Handler(BaseHTTPRequestHandler):
    server_version = "AstfindLocalEmbed/1.0"

    def log_message(self, fmt, *args):  # 不打印请求体；只留一行访问日志
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
            self.send_json(200, {"status": "ok", "model": MODEL_NAME, "dim": DIM, "device": DEVICE})
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
            matrix = embed_texts(items) if kind == "text" else embed_images(items)
            data = [{"object": "embedding", "index": i, "embedding": row.tolist()}
                    for i, row in enumerate(matrix)]
            self.send_json(200, {
                "object": "list", "data": data, "model": payload.get("model") or MODEL_NAME,
                "usage": {"prompt_tokens": 0, "total_tokens": 0},
            })
            print(f"  {kind} n={len(items)} {int((time.perf_counter() - began) * 1000)}ms", flush=True)
        except Exception as exc:  # noqa: BLE001 - 本地实验端点，返回可读错误
            self.send_json(400, {"error": f"{type(exc).__name__}: {exc}"})


def main():
    global MODEL, PROCESSOR, DEVICE, MODEL_NAME, DIM
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--model-name", default="chinese-clip-local")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    args = parser.parse_args()

    MODEL_NAME = args.model_name
    DEVICE = args.device
    torch.set_grad_enabled(False)
    MODEL = ChineseCLIPModel.from_pretrained(args.model_dir, local_files_only=True).eval().to(DEVICE)
    PROCESSOR = ChineseCLIPProcessor.from_pretrained(args.model_dir, local_files_only=True)
    DIM = int(MODEL.config.projection_dim)
    print(f"loaded {args.model_dir} dim={DIM} device={DEVICE}", flush=True)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"listening http://{args.host}:{args.port}/v1/embeddings", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
