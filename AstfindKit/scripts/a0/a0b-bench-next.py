#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A0-b 第二轮：WeMM-2B / EmbeddingGemma 2 本地评测（同一子集 + WeMM-9B 对照）。

复用 a0b-local-bench.py 的取样、缓存、排名与地板工具；只替换本地模型后端。
默认取上一轮 612 图里每个在线源的前 54 张 + 12 张演示图 = 120 张，
保证图片已在 512px 缓存中，不重新打 NAS。

用法（~/.astfind/a0b/.venv）：
  TRANSFORMERS_OFFLINE=1 HF_HUB_OFFLINE=1 \
  ~/.astfind/a0b/.venv/bin/python AstfindKit/scripts/a0/a0b-bench-next.py \
    --backend weemm2b --model-dir ~/.astfind/a0b/weemm-2b \
    --out AstfindKit/scripts/a0/a0b-next-weemm2b.json
  ... --backend gemma2 --model-dir ~/.astfind/a0b/embeddinggemma-2 \
    --out AstfindKit/scripts/a0/a0b-next-gemma2.json
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import resource
import sys
import time

import numpy as np
import torch
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("a0b", os.path.join(HERE, "a0b-local-bench.py"))
a0b = importlib.util.module_from_spec(spec)
sys.modules["a0b"] = a0b  # dataclasses 需要模块已注册
spec.loader.exec_module(a0b)  # main() 有 __main__ 保护，不会执行


def load_backend(kind: str, model_dir: str, dtype: str, device: str):
    from sentence_transformers import SentenceTransformer

    torch_dtype = {"bfloat16": torch.bfloat16, "float16": torch.float16, "float32": torch.float32}[dtype]
    began = time.perf_counter()
    if kind == "weemm2b":
        model = SentenceTransformer(
            model_dir, trust_remote_code=True, device=device,
            model_kwargs={"torch_dtype": torch_dtype},
        )
        dim = int(model.get_sentence_embedding_dimension())
        encode_images = lambda images, batch: model.encode_document(
            images, batch_size=batch, normalize_embeddings=True, show_progress_bar=True)
        encode_texts = lambda texts: model.encode_query(texts, normalize_embeddings=True)
    elif kind == "gemma2":
        model = SentenceTransformer(
            model_dir, device=device,
            model_kwargs={"torch_dtype": torch.float32},
            config_kwargs={"audio_config": None},
        )
        dim = int(model.get_sentence_embedding_dimension())
        # 图片不加任务前缀；文本查询用 SearchQuery 前缀（模型卡推荐）。
        encode_images = lambda images, batch: model.encode(
            images, batch_size=batch, normalize_embeddings=True, show_progress_bar=True)
        encode_texts = lambda texts: model.encode(
            texts, prompt_name="SearchQuery", normalize_embeddings=True)
    else:
        raise SystemExit(f"unknown backend {kind}")
    load_s = time.perf_counter() - began
    return model, dim, load_s, encode_images, encode_texts


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", required=True, choices=["weemm2b", "gemma2"])
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--db", default=a0b.DEFAULT_DB)
    parser.add_argument("--profile", default="wemm-image-v1")
    parser.add_argument("--providers", default=a0b.DEFAULT_PROVIDERS)
    parser.add_argument("--queries", default=a0b.QUERIES_TSV)
    parser.add_argument("--cache-dir", default=a0b.DEFAULT_CACHE)
    parser.add_argument("--per-source", type=int, default=300, help="上一轮取样规模（用于对齐缓存）")
    parser.add_argument("--limit-per-source", type=int, default=54)
    parser.add_argument("--batch", type=int, default=2)
    parser.add_argument("--dtype", default="bfloat16", choices=["bfloat16", "float16", "float32"])
    parser.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    wall = time.perf_counter()
    queries = a0b.load_queries(args.queries)
    samples, sample_meta = a0b.load_samples(args.db, args.profile, args.per_source, 42)
    demo = [s for s in samples if "Astfind演示/" in s.relative_path]
    demo_ids = {s.asset_id for s in demo}
    by_source: dict[str, list] = {}
    for s in samples:
        if s.asset_id not in demo_ids:
            by_source.setdefault(s.source_id, []).append(s)
    picked = demo + [s for sid in sorted(by_source) for s in by_source[sid][:args.limit_per_source]]
    print(f"子集 {len(picked)}（demo {len(demo)}；每源 ≤{args.limit_per_source}）"
          f" 来源={ {sid: len(v[:args.limit_per_source]) for sid, v in by_source.items()} }")

    cache_start = time.perf_counter()
    a0b.cache_images(picked, args.cache_dir, workers=8)
    usable = [s for s in picked if s.cached_path and s.vector_blob]
    failed = [s for s in picked if not s.cached_path]
    print(f"缓存 {time.perf_counter() - cache_start:.1f}s；可嵌入 {len(usable)}，失败 {len(failed)}")
    if not usable:
        raise SystemExit("没有可用图片")

    print(f"加载 {args.backend} …")
    model, dim, load_s, encode_images, encode_texts = load_backend(args.backend, args.model_dir, args.dtype, args.device)
    print(f"  模型 {dim} 维，加载 {load_s:.1f}s")

    images = []
    for s in usable:
        with Image.open(s.cached_path) as image:
            images.append(image.convert("RGB"))
    began = time.perf_counter()
    image_vectors = np.asarray(encode_images(images, args.batch), dtype=np.float32)
    image_s = time.perf_counter() - began
    image_vectors = a0b.unit(image_vectors)
    print(f"  图像 {image_vectors.shape[0]} × {image_vectors.shape[1]}，{image_s:.1f}s"
          f"（{image_s * 1000 / len(images):.1f}ms/张）")

    prompts = [q["text"] for q in queries]
    began = time.perf_counter()
    text_vectors = np.asarray(encode_texts(prompts), dtype=np.float32)
    text_s = time.perf_counter() - began
    text_vectors = a0b.unit(text_vectors)
    print(f"  文本 {text_vectors.shape[0]} 条，{text_s:.0f}ms（{text_s * 1000 / len(prompts):.1f}ms/条）")

    # WeMM-9B 对照：同批库向量 + 在线文本向量
    weemm_vectors = a0b.dequantize([s.vector_blob for s in usable])
    endpoint, model_name = a0b.load_wemm_config(args.providers)
    began = time.perf_counter()
    weemm_text = a0b.unit(np.stack([a0b.embed_text_wemm(endpoint, model_name, q["text"]) for q in queries]).astype(np.float32))
    weemm_text_s = time.perf_counter() - began
    print(f"  WeMM-9B 文本 {weemm_text_s:.0f}ms")

    model_scores = text_vectors @ image_vectors.T
    weemm_scores = weemm_text @ weemm_vectors.T

    results = []
    for i, query in enumerate(queries):
        model_hits = a0b.top_hits(model_scores[i], usable, args.top)
        weemm_hits = a0b.top_hits(weemm_scores[i], usable, args.top)
        eligible = any(any(t in s.relative_path for t in query["expect"]) for s in usable) if query["expect"] else False
        mr, ms = a0b.first_expected_rank(model_hits, query["expect"]) if query["expect"] else (None, None)
        wr, ws = a0b.first_expected_rank(weemm_hits, query["expect"]) if query["expect"] else (None, None)
        results.append({**query, "image_eligible": eligible,
                        "model": {"hits": model_hits, "truth_rank": mr, "truth_score": ms},
                        "weemm": {"hits": weemm_hits, "truth_rank": wr, "truth_score": ws}})

    def aggregate(label: str) -> dict:
        gt = [r for r in results if r["category"] == "gt" and r["image_eligible"]]
        ranks = [r[label]["truth_rank"] for r in gt]
        hits = [r for r in ranks if r]
        return {
            "gt_queries": len(gt),
            "hit1": sum(1 for r in ranks if r == 1),
            "hit5": sum(1 for r in ranks if r and r <= 5),
            "hit10": sum(1 for r in ranks if r and r <= 10),
            "hit20": sum(1 for r in ranks if r and r <= 20),
            "mrr20": round(sum(1.0 / r for r in hits) / len(gt), 4) if gt else 0.0,
        }

    model_agg = aggregate("model")
    weemm_agg = aggregate("weemm")
    floors_model = a0b.floor_table(results, "model")
    floors_weemm = a0b.floor_table(results, "weemm")

    def hub(label: str) -> dict:
        counts = {}
        for r in results:
            for h in r[label]["hits"][:10]:
                counts[h["path"]] = counts.get(h["path"], 0) + 1
        hubs = sorted(counts.items(), key=lambda kv: -kv[1])[:5]
        return {"paths": len(counts), "gini": round(a0b.gini(list(counts.values())), 3),
                "top": [{"path": p, "count": c} for p, c in hubs]}

    generic = []
    for r in results:
        if r["category"] != "generic":
            continue
        m = r["model"]["hits"][0] if r["model"]["hits"] else None
        w = r["weemm"]["hits"][0] if r["weemm"]["hits"] else None
        generic.append({"query": r["text"], "model": m, "weemm": w,
                        "same_asset": bool(m and w and m["asset_id"] == w["asset_id"])})

    summary = {
        "backend": args.backend,
        "model_dir": args.model_dir,
        "device": args.device,
        "dtype": args.dtype,
        "dim": dim,
        "subset": len(usable),
        "demo": len(demo),
        "per_source_limit": args.limit_per_source,
        "load_s": round(load_s, 2),
        "image_s": round(image_s, 2),
        "image_ms": round(image_s * 1000 / len(images), 2),
        "text_ms": round(text_s * 1000 / len(prompts), 2),
        "weemm_text_ms": round(weemm_text_s * 1000 / len(prompts), 2),
        "memory_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // (1024 * 1024),
        "model_agg": model_agg,
        "weemm_agg": weemm_agg,
        "model_floor_table": floors_model,
        "weemm_floor_table": floors_weemm,
        "model_hub": hub("model"),
        "weemm_hub": hub("weemm"),
        "generic": generic,
        "wall_s": round(time.perf_counter() - wall, 1),
    }
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"summary": summary, "results": results}, fh, ensure_ascii=False, indent=1)

    print("\n== 真值 ==")
    print("  本地:", model_agg)
    print("  WeMM-9B:", weemm_agg)
    print("\n== 地板（本地） ==")
    for row in floors_model:
        print("  " + " ".join(f"{k}={v}" for k, v in row.items() if k in ("floor", "leak_queries", "leak_hits", "truth_queries", "generic_top1")))
    print("\n== hub ==")
    print("  本地:", summary["model_hub"])
    print("  WeMM-9B:", summary["weemm_hub"])
    print("\n== 通用 top1 ==")
    for row in generic:
        m, w = row["model"], row["weemm"]
        print(f"  {row['query']}: model={m['score']:.3f} {os.path.basename(m['path']) if m else '-'}"
              f" | weemm={w['score']:.3f} {os.path.basename(w['path']) if w else '-'}"
              f" | same={row['same_asset']}")
    print(f"\n时延：图 {summary['image_ms']}ms/张 · 文本 {summary['text_ms']}ms/条 · "
          f"峰值 {summary['memory_mb']}MB · 总 {summary['wall_s']}s")
    print(f"结果已写 {args.out}")


if __name__ == "__main__":
    main()
