#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A0-b：本地图文模型 vs WeMM 的同查询集/同样本基准。

做什么：
  1) 从生产 registry 只读抽一批在线图片（每源 N 张 + 演示语料全部），
     同时取该批图的 WeMM 向量（wemm-image-v1）；
  2) 用本地 Chinese-CLIP 对同一批图算向量、对 a0-queries-zh.tsv 算文本向量；
  3) WeMM 侧用同一批图的库里向量 + 在线文本向量；
  4) 输出：真值 rank@1/5/10/20、负例泄漏随地板变化、通用查询 top1、hub、
     读盘/预处理/前向时延、峰值内存。

用法（需在装有 torch/transformers 的 venv 里跑）：
  ~/.astfind/a0b/.venv/bin/python AstfindKit/scripts/a0/a0b-local-bench.py \
      --model-dir ~/.astfind/a0b/chinese-clip-vit-b16 \
      --cache-dir ~/.astfind/a0b/cache \
      --per-source 1000 --out AstfindKit/scripts/a0/a0b-results.json

结果含真实路径，a0b-results.json 已 gitignore，勿提交公开仓库。
"""
from __future__ import annotations

import argparse
import json
import os
import random
import resource
import sqlite3
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Iterable

import numpy as np
from PIL import Image, ImageOps

HOME = os.path.expanduser("~")
DEFAULT_DB = f"{HOME}/Library/Application Support/Astfind/registry.sqlite"
DEFAULT_PROVIDERS = f"{HOME}/Library/Application Support/Astfind/providers.json"
DEFAULT_MODEL = f"{HOME}/.astfind/a0b/chinese-clip-vit-b16"
DEFAULT_CACHE = f"{HOME}/.astfind/a0b/cache"
QUERIES_TSV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "a0-queries-zh.tsv")
IMAGE_EXT = (".jpg", ".jpeg", ".png", ".webp", ".heic")
CACHE_MAX_EDGE = 512


@dataclass
class Sample:
    asset_id: str
    source_id: str
    relative_path: str
    mount_path: str
    segment_id: str
    vector_blob: bytes | None = None
    image_path: str = ""
    cached_path: str = ""
    cache_ms: float = 0.0
    cache_error: str = ""

    @property
    def display_path(self) -> str:
        return self.relative_path


def load_queries(path: str) -> list[dict]:
    queries: list[dict] = []
    with open(path, encoding="utf-8") as fh:
        header = fh.readline()
        if not header.startswith("查询"):
            raise SystemExit(f"查询集表头不对: {header!r}")
        for line in fh:
            cells = line.rstrip("\n").split("\t")
            if not cells or not cells[0]:
                continue
            queries.append({
                "text": cells[0],
                "category": cells[1] if len(cells) > 1 else "generic",
                "expect": [e for e in (cells[2].split("|") if len(cells) > 2 and cells[2] else []) if e],
            })
    return queries


def load_samples(db_path: str, profile: str, per_source: int, seed: int) -> tuple[list[Sample], dict]:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    meta_sql = """
        SELECT a.asset_id, a.source_id, a.relative_path, s.mount_path, m.segment_id
        FROM assets a
        JOIN storage_sources s ON s.source_id = a.source_id
        JOIN media_segments m ON m.asset_id = a.asset_id AND m.kind = 'image'
        JOIN embeddings e ON e.segment_id = m.segment_id AND e.profile_id = ?
        WHERE a.deleted_confirmed_at IS NULL
          AND s.online_state = 'online'
          AND s.mount_path IS NOT NULL
          AND a.relative_path NOT LIKE '%/._%'
          AND a.relative_path NOT LIKE '._%'
          AND (lower(a.relative_path) LIKE '%.jpg' OR lower(a.relative_path) LIKE '%.jpeg'
               OR lower(a.relative_path) LIKE '%.png' OR lower(a.relative_path) LIKE '%.webp'
               OR lower(a.relative_path) LIKE '%.heic')
    """
    rows = con.execute(meta_sql, (profile,)).fetchall()
    if not rows:
        raise SystemExit("没有可用的在线图片向量样本")

    # 一个 asset 可能因历史重建有多个 image segment；按 asset_id 去重（保留第一个）。
    by_asset: dict[str, tuple] = {}
    for row in rows:
        by_asset.setdefault(row[0], row)
    rows = list(by_asset.values())

    rng = random.Random(seed)
    demo = [r for r in rows if "Astfind演示/" in r[2]]
    demo_ids = {r[0] for r in demo}
    by_source: dict[str, list[tuple]] = {}
    for row in rows:
        if row[0] in demo_ids:
            continue
        by_source.setdefault(row[1], []).append(row)

    picked: list[tuple] = []
    picked.extend(demo)
    for source_id, source_rows in sorted(by_source.items()):
        if per_source > 0:
            picked.extend(rng.sample(source_rows, min(per_source, len(source_rows))))

    # 取这批 asset 的 WeMM 向量（segment_id 已在元数据里）。
    segment_ids = [r[4] for r in picked]
    blobs: dict[str, bytes] = {}
    for begin in range(0, len(segment_ids), 400):
        chunk = segment_ids[begin:begin + 400]
        marks = ",".join("?" for _ in chunk)
        for seg, blob in con.execute(
                f"SELECT segment_id, vector_blob FROM embeddings WHERE profile_id = ? AND segment_id IN ({marks})",
                [profile, *chunk]):
            blobs[seg] = bytes(blob)
    con.close()

    samples: list[Sample] = []
    for asset_id, source_id, relative_path, mount_path, segment_id in picked:
        image_path = os.path.join(mount_path, relative_path)
        samples.append(Sample(asset_id, source_id, relative_path, mount_path, segment_id,
                              vector_blob=blobs.get(segment_id), image_path=image_path))
    meta = {
        "eligible": len(rows),
        "demo": len(demo),
        "per_source": per_source,
        "sources": {sid: len(v) for sid, v in by_source.items()},
        "selected": len(samples),
        "with_wemm_vector": sum(1 for s in samples if s.vector_blob),
    }
    return samples, meta


def cache_images(samples: list[Sample], cache_dir: str, workers: int) -> None:
    os.makedirs(cache_dir, exist_ok=True)

    def one(sample: Sample) -> None:
        if sample.vector_blob is None:
            sample.cache_error = "no_wemm_vector"
            return
        stem = os.path.join(cache_dir, sample.asset_id + ".jpg")
        if os.path.exists(stem):
            sample.cached_path = stem
            sample.cache_ms = 0.0
            return
        began = time.perf_counter()
        try:
            with Image.open(sample.image_path) as image:
                image = ImageOps.exif_transpose(image).convert("RGB")
                image.thumbnail((CACHE_MAX_EDGE, CACHE_MAX_EDGE), Image.Resampling.LANCZOS)
                image.save(stem, "JPEG", quality=88)
            sample.cached_path = stem
        except Exception as exc:  # noqa: BLE001 - 单图失败不应拖垮基准
            sample.cache_error = f"{type(exc).__name__}: {exc}"
        sample.cache_ms = (time.perf_counter() - began) * 1000

    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(one, samples))


def load_local_model(model_dir: str, device: str):
    import torch
    from transformers import ChineseCLIPModel, ChineseCLIPProcessor

    model = ChineseCLIPModel.from_pretrained(model_dir, local_files_only=True).eval()
    processor = ChineseCLIPProcessor.from_pretrained(model_dir, local_files_only=True)
    torch.set_grad_enabled(False)
    model.to(torch.device(device))
    return model, processor, torch


def embed_images_local(model, processor, torch, paths: list[str], batch: int, device: str):
    arrays: list[np.ndarray] = []
    pre_ms = 0.0
    fwd_ms = 0.0
    got: list[str] = []
    for begin in range(0, len(paths), batch):
        chunk = paths[begin:begin + batch]
        images = []
        for path in chunk:
            with Image.open(path) as image:
                images.append(image.convert("RGB"))
        began = time.perf_counter()
        inputs = processor(images=images, return_tensors="pt")
        pre_ms += (time.perf_counter() - began) * 1000
        inputs = {k: v.to(device) for k, v in inputs.items()}
        began = time.perf_counter()
        features = model.get_image_features(**inputs)
        features = features / features.norm(dim=-1, keepdim=True)
        fwd_ms += (time.perf_counter() - began) * 1000
        arrays.append(features.detach().cpu().numpy().astype(np.float32))
        got.extend(chunk)
    return (np.concatenate(arrays, axis=0) if arrays else np.zeros((0, 0), dtype=np.float32),
            pre_ms, fwd_ms, got)


def embed_text_local(model, processor, torch, texts: list[str], device: str):
    began = time.perf_counter()
    inputs = processor(text=texts, return_tensors="pt", padding=True, truncation=True, max_length=64)
    inputs = {k: v.to(device) for k, v in inputs.items()}
    features = model.get_text_features(**inputs)
    features = features / features.norm(dim=-1, keepdim=True)
    elapsed = (time.perf_counter() - began) * 1000
    return features.detach().cpu().numpy().astype(np.float32), elapsed


def load_wemm_config(path: str) -> tuple[str, str]:
    with open(path, encoding="utf-8") as fh:
        config = json.load(fh)
    providers = config.get("httpEmbeddings") or []
    if not providers:
        raise SystemExit("providers.json 无 httpEmbeddings，无法跑 WeMM 对照")
    return providers[0]["endpoint"], providers[0].get("model", "wemm")


def embed_text_wemm(endpoint: str, model: str, text: str, retries: int = 2) -> np.ndarray:
    body = json.dumps({"model": model, "input": text}).encode("utf-8")
    for attempt in range(retries + 1):
        try:
            request = urllib.request.Request(endpoint, data=body, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=60) as response:
                payload = json.load(response)
            return np.asarray(payload["data"][0]["embedding"], dtype=np.float32)
        except Exception as exc:  # noqa: BLE001
            if attempt == retries:
                raise
            print(f"  WeMM 文本重试({attempt + 1}/{retries}): {exc}", file=sys.stderr)
            time.sleep(2)
    raise RuntimeError("unreachable")


def dequantize(blobs: Iterable[bytes]) -> np.ndarray:
    vectors = []
    for blob in blobs:
        scale = np.frombuffer(blob[:4], dtype="<f4")[0]
        vectors.append(np.frombuffer(blob[4:], dtype=np.int8).astype(np.float32) * (float(scale) / 127.0))
    matrix = np.stack(vectors).astype(np.float32)
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return matrix / norms


def unit(matrix: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(matrix, axis=-1, keepdims=True)
    norms[norms == 0] = 1.0
    return matrix / norms


def top_hits(scores: np.ndarray, samples: list[Sample], top: int) -> list[dict]:
    order = np.argsort(-scores, kind="stable")[:top]
    return [{"rank": i + 1, "score": float(scores[j]),
             "path": samples[j].relative_path, "asset_id": samples[j].asset_id,
             "source_id": samples[j].source_id} for i, j in enumerate(order)]


def first_expected_rank(hits: list[dict], expect: list[str]) -> tuple[int | None, float | None]:
    for hit in hits:
        if any(token in hit["path"] for token in expect):
            return hit["rank"], hit["score"]
    return None, None


def gini(values: list[int]) -> float:
    arr = np.sort(np.asarray(values, dtype=np.float64))
    n = len(arr)
    if n == 0 or arr.sum() <= 0:
        return 0.0
    index = np.arange(1, n + 1)
    return float((2.0 * (index * arr).sum()) / (n * arr.sum()) - (n + 1.0) / n)


def floor_table(results: list[dict], label: str) -> list[dict]:
    """在 top-N 命中上扫地板：负例泄漏 vs 真值保留 vs 通用 top1 保留。"""
    rows = []
    for floor in [round(x * 0.05, 2) for x in range(4, 15)]:  # 0.20 .. 0.70
        leak_queries = 0
        leak_hits = 0
        for result in results:
            if result["category"] != "nonsense":
                continue
            leaked = [h for h in result[label]["hits"] if h["score"] >= floor]
            if leaked:
                leak_queries += 1
            leak_hits += len(leaked)
        truth_queries = 0
        truth_hits = 0
        for result in results:
            if result["category"] != "gt" or not result["image_eligible"]:
                continue
            rank, score = first_expected_rank(result[label]["hits"], result["expect"])
            if rank and score is not None and score >= floor:
                truth_queries += 1
                truth_hits += 1
        generic_top1 = 0
        for result in results:
            if result["category"] == "generic" and result[label]["hits"]:
                if result[label]["hits"][0]["score"] >= floor:
                    generic_top1 += 1
        rows.append({"floor": floor, "leak_queries": leak_queries, "leak_hits": leak_hits,
                     "truth_queries": truth_queries, "generic_top1": generic_top1})
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--profile", default="wemm-image-v1")
    parser.add_argument("--queries", default=QUERIES_TSV)
    parser.add_argument("--providers", default=DEFAULT_PROVIDERS)
    parser.add_argument("--model-dir", default=DEFAULT_MODEL)
    parser.add_argument("--model-name", default="OFA-Sys/chinese-clip-vit-base-patch16")
    parser.add_argument("--cache-dir", default=DEFAULT_CACHE)
    parser.add_argument("--per-source", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--batch", type=int, default=32)
    parser.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "a0b-results.json"))
    parser.add_argument("--skip-wemm", action="store_true", help="只跑本地（WeMM 端点不可用时）")
    parser.add_argument("--text-template", default="{query}", help="本地文本提示模板，如 一张{query}的照片")
    args = parser.parse_args()

    wall = time.perf_counter()
    queries = load_queries(args.queries)
    print(f"查询 {len(queries)} 条；模型 {args.model_dir}")
    samples, sample_meta = load_samples(args.db, args.profile, args.per_source, args.seed)
    print(f"样本 {sample_meta['selected']}（demo {sample_meta['demo']}，带 WeMM 向量 "
          f"{sample_meta['with_wemm_vector']}）：{sample_meta['sources']}")

    print("缓存图片（本地 512px；SMB 读盘与解码是产品真实成本，单独计时）…")
    cache_start = time.perf_counter()
    cache_images(samples, args.cache_dir, args.workers)
    cache_wall = time.perf_counter() - cache_start
    ok = [s for s in samples if s.cached_path and s.vector_blob]
    failed = [s for s in samples if not s.cached_path]
    print(f"  可嵌入 {len(ok)}，失败 {len(failed)}，缓存耗时 {cache_wall:.1f}s")
    if not ok:
        raise SystemExit("没有成功缓存的图片")

    model, processor, torch = load_local_model(args.model_dir, args.device)
    print("本地模型就绪；开始图像向量化…")
    local_start = time.perf_counter()
    local_images, pre_ms, fwd_ms, _ = embed_images_local(
        model, processor, torch, [s.cached_path for s in ok], args.batch, args.device)
    local_wall = time.perf_counter() - local_start
    print(f"  图像 {local_images.shape[0]} × {local_images.shape[1]}，总 {local_wall:.1f}s，"
          f"预处理 {pre_ms:.0f}ms，前向 {fwd_ms:.0f}ms")

    local_prompts = [args.text_template.format(query=q["text"]) for q in queries]
    local_text, local_text_ms = embed_text_local(model, processor, torch, local_prompts, args.device)
    print(f"  本地文本 {local_text.shape[0]} 条，{local_text_ms:.0f}ms")

    weemm_vectors = dequantize([s.vector_blob for s in ok])
    weemm_text = None
    weemm_text_ms = []
    weemm_error = None
    if not args.skip_wemm:
        endpoint, model_name = load_wemm_config(args.providers)
        print(f"WeMM 文本向量：{endpoint} model={model_name}")
        try:
            vectors = []
            for query in queries:
                began = time.perf_counter()
                vectors.append(embed_text_wemm(endpoint, model_name, query["text"]))
                weemm_text_ms.append((time.perf_counter() - began) * 1000)
            weemm_text = unit(np.stack(vectors).astype(np.float32))
        except Exception as exc:  # noqa: BLE001
            weemm_error = f"{type(exc).__name__}: {exc}"
            print(f"  WeMM 文本失败：{weemm_error}", file=sys.stderr)

    local_scores = unit(local_text) @ local_images.T
    weemm_scores = unit(weemm_text) @ weemm_vectors.T if weemm_text is not None else None

    results = []
    for i, query in enumerate(queries):
        local_hits = top_hits(local_scores[i], ok, args.top)
        weemm_hits = top_hits(weemm_scores[i], ok, args.top) if weemm_scores is not None else []
        # 只把 sample 里确实有目标图的真值查询计入聚合；纯视频目标会标 unsupported。
        image_eligible = any(any(token in s.relative_path for token in query["expect"]) for s in ok) if query["expect"] else False
        local_rank, local_score = first_expected_rank(local_hits, query["expect"]) if query["expect"] else (None, None)
        weemm_rank, weemm_score = first_expected_rank(weemm_hits, query["expect"]) if query["expect"] and weemm_hits else (None, None)
        results.append({
            **query,
            "image_eligible": image_eligible,
            "local": {"hits": local_hits, "truth_rank": local_rank, "truth_score": local_score},
            "weemm": {"hits": weemm_hits, "truth_rank": weemm_rank, "truth_score": weemm_score},
        })

    def aggregate(label: str) -> dict:
        gt = [r for r in results if r["category"] == "gt" and r["image_eligible"]]
        ranks = [r[label]["truth_rank"] for r in gt]
        hits = [r for r in ranks if r]
        mrr = sum(1.0 / r for r in hits) / len(gt) if gt else 0.0
        return {
            "gt_queries": len(gt),
            "hit1": sum(1 for r in ranks if r == 1),
            "hit5": sum(1 for r in ranks if r and r <= 5),
            "hit10": sum(1 for r in ranks if r and r <= 10),
            "hit20": sum(1 for r in ranks if r and r <= 20),
            "mrr20": round(mrr, 4),
        }

    local_agg = aggregate("local")
    weemm_agg = aggregate("weemm") if weemm_text is not None else {}
    floors_local = floor_table(results, "local")
    floors_weemm = floor_table(results, "weemm") if weemm_text is not None else []

    # hub：top-10 路径出现次数
    def hub(label: str) -> dict:
        counts: dict[str, int] = {}
        for r in results:
            for h in r[label]["hits"][:10]:
                counts[h["path"]] = counts.get(h["path"], 0) + 1
        hubs = sorted(counts.items(), key=lambda kv: -kv[1])[:5]
        return {"paths": len(counts), "gini": round(gini(list(counts.values())), 3),
                "top": [{"path": p, "count": c} for p, c in hubs]}

    # 通用查询 top1 对照
    generic = []
    for r in results:
        if r["category"] != "generic":
            continue
        local_top = r["local"]["hits"][0] if r["local"]["hits"] else None
        weemm_top = r["weemm"]["hits"][0] if r["weemm"]["hits"] else None
        generic.append({
            "query": r["text"],
            "local": local_top,
            "weemm": weemm_top,
            "same_asset": bool(local_top and weemm_top and local_top["asset_id"] == weemm_top["asset_id"]),
        })

    summary = {
        "model": args.model_name,
        "text_template": args.text_template,
        "device": args.device,
        "profile": args.profile,
        "sample": sample_meta,
        "embedded": len(ok),
        "cache_failures": len(failed),
        "cache_wall_s": round(cache_wall, 2),
        "cache_ms_mean": round(float(np.mean([s.cache_ms for s in ok])), 2),
        "local_image_total_s": round(local_wall, 2),
        "local_image_per_ms": round(local_wall * 1000 / len(ok), 2),
        "local_preprocess_ms": round(pre_ms, 1),
        "local_forward_ms": round(fwd_ms, 1),
        "local_text_ms": round(local_text_ms, 1),
        "weemm_text_ms_mean": round(float(np.mean(weemm_text_ms)), 1) if weemm_text_ms else None,
        "weemm_error": weemm_error,
        "local_agg": local_agg,
        "weemm_agg": weemm_agg,
        "local_floor_table": floors_local,
        "weemm_floor_table": floors_weemm,
        "local_hub": hub("local"),
        "weemm_hub": hub("weemm") if weemm_text is not None else None,
        "generic": generic,
        "memory_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // (1024 * 1024),
        "wall_s": round(time.perf_counter() - wall, 1),
    }

    payload = {"summary": summary, "results": results}
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)

    print("\n== 真值（sample 内有目标图的查询） ==")
    print(f"  本地: {local_agg}")
    print(f"  WeMM: {weemm_agg}")
    print("\n== 负例/地板（本地） ==")
    for row in floors_local:
        print("  " + " ".join(f"{k}={v}" for k, v in row.items()))
    if floors_weemm:
        print("\n== 负例/地板（WeMM） ==")
        for row in floors_weemm:
            print("  " + " ".join(f"{k}={v}" for k, v in row.items()))
    print("\n== hub ==")
    print("  本地:", summary["local_hub"])
    if summary["weemm_hub"]:
        print("  WeMM:", summary["weemm_hub"])
    print("\n== 通用查询 top1 ==")
    for row in generic:
        l = row["local"]
        w = row["weemm"]
        print(f"  {row['query']}: local={l['score']:.3f} {os.path.basename(l['path']) if l else '-'}"
              f" | weemm={w['score']:.3f} {os.path.basename(w['path']) if w else '-'}"
              f" | same={row['same_asset']}")
    print(f"\n时延：图 {summary['local_image_per_ms']}ms/张（前向 {summary['local_forward_ms']:.0f}ms）"
          f" · 文本 {summary['local_text_ms']:.0f}ms · 峰值 {summary['memory_mb']}MB")
    print(f"结果已写 {args.out}")


if __name__ == "__main__":
    main()
