#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A0-a 语义检索基准：相似度地板 / 均值中心化 / hub 效应 一遍测完。

零产品侵入：只读连接拉全量 int8 向量（WAL 并发，不动 App 泵），查询文本直连
providers.json 里配置的 WeMM 端点（与产品 embedText 同 payload）。中心化与非中心化
在同一个分块扫描里同时打分，各自维护完整 top-N 榜单。

用法:
  python3 a0-bench.py [--top 20] [--out a0-results.json]
依赖: numpy；结果含真实路径，勿提交公开仓库（.gitignore 已排除）。
"""
import argparse
import json
import os
import sqlite3
import sys
import time
import urllib.request

import numpy as np

HOME = os.path.expanduser("~")
DEFAULT_DB = f"{HOME}/Library/Application Support/Astfind/registry.sqlite"
DEFAULT_PROVIDERS = f"{HOME}/Library/Application Support/Astfind/providers.json"
DEFAULT_PROFILE = "wemm-image-v1"
QUERIES_TSV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "a0-queries-zh.tsv")

SQL = """
SELECT e.segment_id, a.asset_id, a.relative_path, s.kind, s.start_ms, e.vector_blob
FROM embeddings e
JOIN media_segments s ON s.segment_id = e.segment_id
JOIN assets a ON a.asset_id = s.asset_id AND a.deleted_confirmed_at IS NULL
WHERE e.profile_id = ?
"""


def load_provider_endpoint():
    with open(DEFAULT_PROVIDERS, encoding="utf-8") as fh:
        config = json.load(fh)
    providers = config.get("httpEmbeddings") or []
    if not providers:
        raise SystemExit("providers.json 无 httpEmbeddings")
    return providers[0]["endpoint"], providers[0].get("model", "wemm")


def embed_text(endpoint, model, text, retries=2):
    body = json.dumps({"model": model, "input": text}).encode("utf-8")
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(endpoint, data=body,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                payload = json.load(resp)
            return np.asarray(payload["data"][0]["embedding"], dtype=np.float32)
        except Exception as exc:  # noqa: BLE001 - 评测脚本，任何网络错误都重试
            if attempt == retries:
                raise
            print(f"  embed 重试({attempt + 1}/{retries}): {exc}", file=sys.stderr)
            time.sleep(2)


def load_vectors(db_path, profile):
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    rows = con.execute(SQL, (profile,)).fetchall()
    con.close()
    if not rows:
        raise SystemExit("无向量")
    n, dim = len(rows), len(rows[0][5]) - 4
    vectors = np.empty((n, dim), dtype=np.int8)
    scales = np.empty(n, dtype=np.float32)
    meta = []
    for i, (seg, asset, path, kind, start_ms, blob) in enumerate(rows):
        scales[i] = np.frombuffer(blob[:4], dtype="<f4")[0]
        vectors[i] = np.frombuffer(blob[4:], dtype=np.int8)
        meta.append({"segment_id": seg, "asset_id": asset, "path": path,
                     "kind": kind, "start_ms": start_ms})
    return vectors, scales, meta, dim


def block_iter(n, block=8192):
    for begin in range(0, n, block):
        yield begin, min(begin + block, n)


def unit(v):
    norm = float(np.linalg.norm(v))
    return v / norm if norm > 0 else v


def gini(values):
    arr = np.sort(np.asarray(values, dtype=np.float64))
    n = len(arr)
    if n == 0 or arr.sum() <= 0:
        return 0.0
    index = np.arange(1, n + 1)
    return float((2.0 * (index * arr).sum()) / (n * arr.sum()) - (n + 1.0) / n)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--profile", default=DEFAULT_PROFILE)
    parser.add_argument("--queries", default=QUERIES_TSV)
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--out", default=os.path.join(os.path.dirname(
        os.path.abspath(__file__)), "a0-results.json"))
    args = parser.parse_args()

    endpoint, model = load_provider_endpoint()
    print(f"载入向量（只读）: {args.db} profile={args.profile}")
    t0 = time.time()
    vectors, scales, meta, dim = load_vectors(args.db, args.profile)
    print(f"  {vectors.shape[0]} 向量 × {dim} 维，{time.time() - t0:.1f}s")

    # 均值与中心化范数（两遍分块扫描；避免整表 float32 物化 ~1.9GB）
    # 注意：真值向量 = int8 × 每向量 scale/127（EmbeddingIndexer 量化约定），均值必须按带 scale 的值算
    t0 = time.time()
    mean = np.zeros(dim, dtype=np.float64)
    for begin, end in block_iter(len(meta)):
        block = vectors[begin:end].astype(np.float32) * (scales[begin:end, None] / 127.0)
        mean += block.sum(axis=0, dtype=np.float64)
    mean = (mean / len(meta)).astype(np.float32)
    centered_norm = np.empty(len(meta), dtype=np.float32)
    for begin, end in block_iter(len(meta)):
        block = vectors[begin:end].astype(np.float32) * (scales[begin:end, None] / 127.0)
        block -= mean
        np.square(block, out=block)
        centered_norm[begin:end] = np.sqrt(block.sum(axis=1))
    print(f"  均值/中心化范数就绪 {time.time() - t0:.1f}s（|μ|={np.linalg.norm(mean):.3f}）")

    # 量化健全性：dequant 自身范数应 ≈1
    sample = vectors[:200].astype(np.float32) * (scales[:200, None] / 127.0)
    quant_norms = np.linalg.norm(sample, axis=1)
    print(f"  量化健全性: dequant 范数 mean={quant_norms.mean():.4f} "
          f"min={quant_norms.min():.4f} max={quant_norms.max():.4f}")

    queries = []
    with open(args.queries, encoding="utf-8") as fh:
        header = fh.readline()
        assert header.startswith("查询"), header
        for line in fh:
            cells = line.rstrip("\n").split("\t")
            if len(cells) >= 2 and cells[0]:
                queries.append({"text": cells[0], "category": cells[1],
                                "expect": cells[2].split("|") if len(cells) > 2 and cells[2] else []})

    results = []
    for qi, query in enumerate(queries, 1):
        q = embed_text(endpoint, model, query["text"])
        if len(q) != dim:
            raise SystemExit(f"查询维度 {len(q)} ≠ {dim}")
        qc = unit(q)
        qcenter = unit(q - mean)
        scores = np.empty(len(meta), dtype=np.float32)
        scores_c = np.empty(len(meta), dtype=np.float32)
        for begin, end in block_iter(len(meta)):
            raw = vectors[begin:end].astype(np.float32)
            # 非中心化: q̂·(int8*scale/127)
            scores[begin:end] = raw @ qc * (scales[begin:end] / 127.0)
            # 中心化: (v*scale/127 - μ)·(q-μ)̂ / |v*scale/127 - μ|
            block = raw * (scales[begin:end, None] / 127.0)
            block -= mean
            denom = centered_norm[begin:end]
            scores_c[begin:end] = np.divide(block @ qcenter, denom,
                                            out=np.zeros(end - begin, dtype=np.float32),
                                            where=denom > 1e-9)
        top_plain = np.argsort(-scores, kind="stable")[: args.top]
        top_center = np.argsort(-scores_c, kind="stable")[: args.top]
        hit_plain = [{"score": float(scores[i]), "score_c": float(scores_c[i]),
                      "path": meta[i]["path"], "kind": meta[i]["kind"],
                      "start_ms": meta[i]["start_ms"]} for i in top_plain]
        hit_center = [{"score": float(scores_c[i]), "path": meta[i]["path"],
                       "kind": meta[i]["kind"]} for i in top_center]
        results.append({**query, "hits": hit_plain, "hits_centered": hit_center})
        first = hit_plain[0]
        print(f"[{qi:02d}/{len(queries)}] {query['text']} | {query['category']:8s} "
              f"top1={first['score']:.3f}({first['score_c']:.3f}) "
              f"{os.path.basename(first['path'])}")

    payload = {"dim": dim, "count": len(meta), "profile": args.profile,
               "top": args.top, "quant_norm_mean": float(quant_norms.mean()),
               "results": results}
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
    print(f"结果已写 {args.out}")

    # ---- 聚合 ----
    nonsense = [r for r in results if r["category"] == "nonsense"]
    generic = [r for r in results if r["category"] == "generic"]
    gt = [r for r in results if r["category"] == "gt"]

    print("\n== 地板分析（负例 top20 内 max 分数，两种模式）==")
    for r in nonsense:
        mx = max((h["score"] for h in r["hits"]), default=0)
        mxc = max((h["score_c"] for h in r["hits"]), default=0)
        flag = " <-- 高于0.35地板" if mx > 0.35 else ""
        print(f"  {r['text'][:18]:22s} max={mx:.3f} centered_max={mxc:.3f}{flag}")

    print("\n== 真值命中（演示语料：两模式各自 top-20 内首次命中位置，1 基）==")
    for r in gt:
        plain = next((i + 1 for i, h in enumerate(r["hits"])
                      if any(e in h["path"] for e in r["expect"])), None)
        centered = next((i + 1 for i, h in enumerate(r["hits_centered"])
                         if any(e in h["path"] for e in r["expect"])), None)
        score = r["hits"][plain - 1]["score"] if plain else float("nan")
        print(f"  {r['text'][:16]:20s} rank={plain or '>20'} score={score:.3f} "
              f"| centered_rank={centered or '>20'}")

    print("\n== hub 效应（各查询 top-10 出现次数按路径聚合）==")
    for label, field in (("非中心化", "hits"), ("中心化", "hits_centered")):
        counts = {}
        for r in results:
            for h in r[field][:10]:
                counts[h["path"]] = counts.get(h["path"], 0) + 1
        total = len(results) * 10
        hubs = sorted(counts.items(), key=lambda kv: -kv[1])[:8]
        print(f"  [{label}] 覆盖 {len(counts)} 路径，Gini={gini(list(counts.values())):.3f}"
              f"（完全均匀=0，单点独占≈1）")
        for path, count in hubs:
            print(f"    {count:3d}× ({count * 100 // total}%) {os.path.basename(path)}")

    print("\n== 通用查询 top1（路径=非中心化 top1；分数: 非中心化 / 该向量中心化分）==")
    for r in generic:
        h = r["hits"][0]
        print(f"  {r['text'][:16]:20s} {h['score']:.3f}({h['score_c']:.3f})"
              f" {os.path.basename(h['path'])}")


if __name__ == "__main__":
    main()
