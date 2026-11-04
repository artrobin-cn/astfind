#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把本地搜索反馈日志（A0-a-2）转成 A0 基准查询集候选。

输入：~/Library/Application Support/Astfind/search-feedback.jsonl（+ 轮转的 .1）
只读本地文件，零网络。输出两件：
  - 候选真值 TSV（query / gt / 文件名主干 / 打开次数），人工过目后并入 a0-queries-zh.tsv
  - 零结果查询清单（stdout，按出现次数降序）——召回缺口，最值得人工判断

用法:
  python3 feedback-to-queries.py [--days 30] [--min-opens 1] [--out feedback-candidates.tsv]
隐私：输出含真实路径/文件名，已在 .gitignore 排除，勿提交公开仓库。
"""
import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

HOME = os.path.expanduser("~")
DEFAULT_LOG = f"{HOME}/Library/Application Support/Astfind/search-feedback.jsonl"
HERE = os.path.dirname(os.path.abspath(__file__))


def iter_entries(path):
    for candidate in (path + ".1", path):
        if not os.path.exists(candidate):
            continue
        with open(candidate, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(entry, dict) and entry.get("query"):
                    yield entry


def parse_time(text):
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def stem(path):
    name = os.path.basename(path or "")
    root, _ = os.path.splitext(name)
    return root or name


def clean(text):
    return " ".join((text or "").split())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", default=DEFAULT_LOG)
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--min-opens", type=int, default=1,
                        help="同一查询同一文件至少被打开几次才进候选（默认 1）")
    parser.add_argument("--out", default=os.path.join(HERE, "feedback-candidates.tsv"))
    args = parser.parse_args()

    if not os.path.exists(args.log) and not os.path.exists(args.log + ".1"):
        print(f"还没有反馈日志：{args.log}\n正常用几天面板搜索后就会长出来。")
        return 0

    cutoff = datetime.now(timezone.utc) - timedelta(days=args.days)
    opens = defaultdict(int)          # (query, path) -> count
    channels = {}                     # (query, path) -> channel
    best_rank = {}                    # (query, path) -> 最小名次
    zeros = Counter()                 # query -> 次数
    total = skipped = 0

    for entry in iter_entries(args.log):
        when = parse_time(entry.get("t"))
        if when is not None and when < cutoff:
            skipped += 1
            continue
        total += 1
        query = clean(entry.get("query"))
        if len(query) < 2:
            continue
        if entry.get("event") == "zero":
            zeros[query] += 1
        elif entry.get("event") in ("open", "reveal") and entry.get("path"):
            key = (query, entry["path"])
            opens[key] += 1
            channels.setdefault(key, entry.get("channel") or "name")
            rank = entry.get("rank")
            if isinstance(rank, int):
                best_rank[key] = min(best_rank.get(key, rank), rank)

    rows = [(q, p, n) for (q, p), n in opens.items() if n >= args.min_opens]
    # 打开次数多的优先；同次数按名次靠前优先
    rows.sort(key=lambda r: (-r[2], best_rank.get((r[0], r[1]), 999), r[0]))

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("查询\t类别\t期望命中(路径包含,|分隔)\t打开次数\n")
        for query, path, count in rows:
            name = stem(path)
            if "\t" in query or "\t" in name:
                continue
            fh.write(f"{query}\tgt\t{name}\t{count}\n")

    distinct_queries = len({q for q, _ in opens})
    print(f"读取 {total} 条事件（{skipped} 条早于 {args.days} 天前）")
    print(f"打开/定位：{len(opens)} 个查询→文件对，{distinct_queries} 个不同查询")
    print(f"候选真值：{len(rows)} 行 → {args.out}")
    channels_count = Counter(channels.values())
    if channels_count:
        print("  按通道：" + "，".join(f"{k} {v}" for k, v in channels_count.most_common()))
    if zeros:
        print(f"\n零结果查询（召回缺口，{len(zeros)} 个不同查询，取前 30）：")
        for query, count in zeros.most_common(30):
            print(f"  {count:3d}× {query}")
    else:
        print("\n零结果查询：无（要么还没遇到，要么四秒内补齐了）")
    print("\n下一步：人工过目候选 TSV，把确认的查询并入 a0-queries-zh.tsv；"
          "零结果清单用于判断是真缺口还是查询本身无意义。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
