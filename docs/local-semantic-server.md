# 本地语义模型：启动与接入

> 面向想用**本机模型**做图片/视频画面语义搜索的用户。App 只连 `127.0.0.1`，零外发；
> 模型与服务都在你自己的机器上。远程端点见设置页「语义模型 → 远程」。

## 为什么 App 不自带运行时

v1 只在 App 里做「配置 + 探测 + 检索」，不做 Python/torch 打包、模型自动下载或 CoreML 原生推理。
理由：模型权重从 1.4GB（EmbeddingGemma 2）到约 19GB（WeMM-9B），许可证、磁盘与网络各不相同；把运行时塞进 App 会显著放大安装包与首启成本。
所以本地模式复用已经验证过的 OpenAI 兼容 Provider 通路——用户自己起服务，App 只发 HTTP。

## 模型选择与下载

权重不随本仓库分发；以下模型均可公开下载。WeMM 与 EmbeddingGemma 2 标注 Apache-2.0（WeMM 的 HF 元数据以 license_name 标注），Chinese-CLIP 以模型卡为准；一切以模型卡与随附 LICENSE 为准。本项目只验证中文教学/活动素材域，下面的分数是 612 图同图配对的相对结果，不是公开榜单。

| 模型 | 参数 | 维度 | 权重 | 硬件建议 | 本项目实测 |
|---|---:|---:|---:|---|---|
| [WeMM-Embedding-2B](https://huggingface.co/tencent/WeMM-Embedding-2B) | 2B | 2048（MRL 64–2048） | ~5.2GB | Apple Silicon 16GB 可跑 | **rank1 11/11、MRR 1.0**；1.06s/图、125ms/查询、峰值 4.76GB |
| [WeMM-Embedding-9B](https://huggingface.co/tencent/WeMM-Embedding-9B) | 9B | 4096（MRL 64–4096） | ~19GB | **需 ≥24GB 显存**（BF16）；16GB Mac 不适合 | 远程基线 rank1 10/11、MRR 0.9545（本项目远程部署，非本机） |
| [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) | 0.74B | 768（MRL 128–768） | ~1.4GB | 轻量，16GB 可跑 | rank1 7/11、MRR 0.818；0.99s/图、17ms/查询、峰值 2.95GB |
| [Chinese-CLIP B/16](https://huggingface.co/OFA-Sys/chinese-clip-vit-base-patch16)（参考） | 188M | 512 | ~753MB | 最轻，CPU 可跑 | rank1 5/11、MRR 0.636；快但本域质量不足 |

> **能力**：这些模型都把文本与图片映射到同一向量空间，可用自然语言搜图片/视频帧；WeMM 额外覆盖视频与视觉文档，EmbeddingGemma 2 还覆盖音频（本项目只用到图片/视频帧）。官方模型卡在 MMEB-v2 / MMEB-v3 上报告了同尺寸领先的成绩（具体分数与口径见模型卡）；本文的 11 条真值是自建域内配对，两者不可直接比较。

```bash
# 下载（Hugging Face；国内可加 HF_ENDPOINT=https://hf-mirror.com）
# 新版 huggingface_hub 用 hf；旧版把 hf 换成 huggingface-cli
hf download tencent/WeMM-Embedding-2B --local-dir ~/models/weemm-2b
hf download google/embeddinggemma-2 --local-dir ~/models/embeddinggemma-2
# 可选：9B，仅建议 ≥24GB 显存的机器
hf download tencent/WeMM-Embedding-9B --local-dir ~/models/weemm-9b
```

> 部分模型卡要求 `trust_remote_code=True` 或特定 transformers 版本；以模型卡为准。WeMM 参考实现：[Tencent/WeMM-Embedding](https://github.com/Tencent/WeMM-Embedding)。

## 前提条件

- macOS 14+，Apple Silicon（MPS）推荐；Intel/无 MPS 可用 CPU（慢一个数量级）。
- Python 3.10+，能安装 `torch`、`pillow`、`sentence-transformers`。
- 模型放本机盘或已挂载的外置盘均可；**不要用 exFAT**，除非先清掉 AppleDouble 边车文件：

  ```bash
  find /path/to/model -name '._*' -delete
  ```

  否则 processor 读到 `._*.jinja` 会报 `UnicodeDecodeError`。

## 一、建 Python 环境

```bash
cd /path/to/astfind          # 仓库根目录
python3 -m venv ~/.astfind/a0b/.venv
~/.astfind/a0b/.venv/bin/pip install torch pillow sentence-transformers
```

> **坑：transformers 版本分裂。** WeMM-2B 与 EmbeddingGemma 2 依赖的 transformers 大版本不同，
> 本项目实测用两个 venv 分别跑（`.venv` 与 `.venv-gemma`）。不要在同一环境里升级降级硬凑，
> 否则另一个模型的 processor 会直接加载失败。

## 二、启动服务

WeMM-2B（端口 8098，MPS float16）：

```bash
~/.astfind/a0b/.venv/bin/python AstfindKit/scripts/a0/a0b-serve-next.py \
  --backend weemm2b --model-dir ~/models/weemm-2b \
  --device mps --dtype float16 --port 8098
```

EmbeddingGemma 2（端口 8097，MPS float32）：

```bash
~/.astfind/a0b/.venv-gemma/bin/python AstfindKit/scripts/a0/a0b-serve-next.py \
  --backend gemma2 --model-dir ~/models/embeddinggemma-2 \
  --device mps --dtype float32 --port 8097
```

### 可选：WeMM-9B（显存要求高）

仓库自带脚本只内置 WeMM-2B 与 EmbeddingGemma 2 两个 backend。9B 约 9.4B 参数，BF16 需约 21GB 显存，
16GB Mac 不适合；如有 24GB 级 GPU，用 vLLM / SGLang 或模型自带服务暴露 OpenAI 兼容 `/v1/embeddings`，
再把 App 的「本地」端点指向 `http://127.0.0.1:<端口>/v1/embeddings`；或部署到内网/公网并用「远程」模式 + 显式外发授权。

脚本要点：

- `--host` 默认 `127.0.0.1`（只监听回环；不要改成 `0.0.0.0`，那等于把模型暴露到局域网）。
- 服务端会把小于 64px 的探针图抬到 64px（App 探测会发 1×1 PNG），并把大图按 **512px 下采样**——
  3000px 原图在 MPS 上 attention buffer 能冲到 15GB，直接 OOM。
- EmbeddingGemma 2 用 `--dtype float32`（或 bfloat16）；float16 会超出激活动态范围，可能 NaN 或静默退化。
- 批量上限按 ≤8 图实现；App 本地预设默认声明 8，探测实测通过才启用。
- 停止：`Ctrl-C`。

## 三、在 App 里接入

1. 设置 → 统一搜索来源 → 展开 → **语义模型** → 选「本地」。
2. 点「配置…」：默认端点 `http://127.0.0.1:8098/v1/embeddings`、模型 `weemm-2b`、批量上限 8。
   本地模式只接受回环地址（`127.0.0.1` / `localhost` / `::1`），填远端会被拒绝。
3. 点「测试连接」。成功显示形如：

   ```
   已连接 · 5110ms · 2048 维 · 图片 · 批量 ×8
   ```

   失败是可读的分类（连不上 / 超时 / 鉴权失败 / 不支持图片 / 服务端错误），并提示本地服务是否已启动。
4. 打开「图片与视频语义索引」——这一步才会**建立向量**（后台进行）。切换模型不会自动重嵌。

CLI 等价操作（调试/无头）：

```bash
.build/debug/astfind-sources providers add-http semantic-local \
  http://127.0.0.1:8098/v1/embeddings weemm-2b \
  --name 本机WeMM --images dataurl --batch 8
.build/debug/astfind-sources providers mode local
.build/debug/astfind-sources providers probe
.build/debug/astfind-sources semantic status
.build/debug/astfind-sources semantic on     # 显式开始建向量
```

## 四、隐私与发送边界

- 本地模式**只**使用回环端点：即便 `allowRemoteEgress` 为 true，远端 Provider 也不会被选中。
- 回环请求视为本地推理，不算外发；文件名/OCR/正文始终本地。
- 关闭语义模型 = 不注册图片 Provider，也不发起任何向量请求。

## 五、切换模型后的向量

向量空间的身份 = 模型 + 预处理 + 维度。换模型（或同模型换维度）会得到新的 profile：

- 旧 profile 的向量**原样保留只读**，绝不与新向量混算；
- 新模型需要重新建立向量：现有 10 万级图片按实测约 1.06s/图、批量 ×8 吞吐估算，需要数十小时；
- 中途可关闭「图片与视频语义索引」暂停，向量与任务都在，之后继续；
- 切回旧模型时旧向量可直接复用（同一 profile 签名）。

存储：int8 量化每向量约 4KB；10 万图约 0.4GB/模型。

## 六、常见问题

| 现象 | 原因与处理 |
|---|---|
| 测试连接「连不上」 | 服务没起；端口不对；`--host` 不是回环。先 `curl http://127.0.0.1:8098/health` 看端口是否在（返回 `{"status":"ok","dim":2048,…}`）。 |
| 「不支持图片」 | 模型/端点只能做文本向量，或图片输入约定不符（脚本约定 `input: [{"image": "data:...;base64,..."}]`）。 |
| 探测通过但批量=串行 | 服务端没按多图返回多向量；App 会自动降回串行，不影响正确性。 |
| 首个请求很慢（数秒到数十秒） | 模型首次加载/编译 kernel；之后查询约百毫秒级。 |
| 处理中内存暴涨或被杀 | 用脚本默认的 512px 下采样，不要改大；关闭其他吃显存的应用。 |
| `UnicodeDecodeError`/`.jinja` | exFAT 的 `._*` 边车；`find … -name '._*' -delete`。 |
| 想换端口 | 启动加 `--port 8099`，App 端点同步改。 |

## 七、与远程模式的关系

两者协议完全一致（OpenAI 兼容 `/v1/embeddings`），只是发送边界不同：

- 远程：非回环端点 + 显式外发授权（未授权时零请求）；
- 本地：回环端点，无需授权，永不外发。

想回退到远程：设置页切「远程」→ 确认原端点与授权 → 打开索引开关；
旧的本机向量保留只读，可随时切回复用。
