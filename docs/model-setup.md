# 模型下载与配置（可选）

> **先说结论**：基础的文件名、正文、OCR、视频帧文字搜索**不需要任何模型**。  
> 只有想启用「本机语义搜画面」或「人物检索 / 找人」时，才需要按需下载并配置下面的模型。  
> App 不打包、不自动下载模型权重；下载即表示你接受对应模型的许可证。

## 我需要哪个模型？

| 想用的能力 | 需要的模型 | 是否必需 | 权重位置 |
|---|---|---|---|
| 文件名 / 正文 / PDF / 图片 OCR / 视频帧文字 | 无 | 不需要 | — |
| 本机语义搜图片 / 视频画面 | **WeMM-Embedding-2B** | 可选 | `~/models/weemm-2b` |
| 远程语义搜画面 | 远端 OpenAI 兼容端点 | 可选 | 不在本机 |
| 人物检索 / 找人 | **buffalo_sc**（识别模型 `w600k_mbf`，需转 CoreML） | 可选 | `~/Library/Application Support/Astfind/models/buffalo_sc.mlmodelc` |

---

## 一、WeMM-2B：本机语义模型

### 1.1 用途与边界

- 用于图片 / 视频画面的自然语言检索；
- 约 **5.2GB** 权重，Apple Silicon 16GB 可运行；
- 权重不随 App / 仓库分发；
- 许可证以 Hugging Face 模型卡为准（本项目记录为 Apache-2.0，使用前请再次核对模型卡与随附 LICENSE）。

### 1.2 下载地址

- 模型主页：<https://huggingface.co/tencent/WeMM-Embedding-2B>
- 参考实现：<https://github.com/Tencent/WeMM-Embedding>

```bash
# 如未安装下载工具
python3 -m pip install -U huggingface_hub

# 新版 huggingface_hub 用 hf；旧版把 hf 换成 huggingface-cli
hf download tencent/WeMM-Embedding-2B --local-dir ~/models/weemm-2b

# 国内网络可尝试镜像
# HF_ENDPOINT=https://hf-mirror.com hf download tencent/WeMM-Embedding-2B --local-dir ~/models/weemm-2b
```

### 1.3 启动本机服务

App 只连接本机回环地址，不内置 Python / torch，也不替你启动服务。完整依赖、transformers 版本坑和 EmbeddingGemma 备选见 [本地语义模型：启动与接入](local-semantic-server.md)。

```bash
# 仓库根目录执行
python3 -m venv ~/.astfind/a0b/.venv
~/.astfind/a0b/.venv/bin/pip install torch pillow sentence-transformers

~/.astfind/a0b/.venv/bin/python AstfindKit/scripts/a0/a0b-serve-next.py \
  --backend weemm2b \
  --model-dir ~/models/weemm-2b \
  --device mps --dtype float16 --port 8098
```

服务只监听 `127.0.0.1:8098`；不要把 `--host` 改成 `0.0.0.0`，那会把模型暴露到局域网。

### 1.4 在 App 中配置

1. 打开 **设置 → 统一搜索来源 → 展开来源 → 语义模型**；
2. 选择 **本地**；
3. 点「配置…」，填写：
   - 端点：`http://127.0.0.1:8098/v1/embeddings`
   - 模型：`weemm-2b`
   - 批量上限：`8`
4. 点「测试连接」，成功应显示类似 `2048 维 · 图片 · 批量 ×8`；
5. 打开「图片与视频语义索引」，才会开始建立向量；
6. 切换模型不会自动重嵌，旧向量会只读保留。

CLI 等价配置：

```bash
astfind-sources providers add-http semantic-local \
  http://127.0.0.1:8098/v1/embeddings weemm-2b \
  --name 本机WeMM --images dataurl --batch 8
astfind-sources providers mode local
astfind-sources providers probe
astfind-sources semantic on
```

### 1.5 验证

```bash
curl http://127.0.0.1:8098/health
# 预期返回 status: ok 与维度信息
```

如果连不上：先确认 Python 服务仍在运行、端口是 8098、地址是回环地址。故障分类与模型对比见 [本地语义模型：启动与接入](local-semantic-server.md)。

---

## 二、buffalo_sc：人物检索模型

### 2.1 用途与许可边界

- 用于参考照片 → 人脸检测/对齐 → 512 维向量 → 本机人脸索引；
- 识别模型为 InsightFace `buffalo_sc` 中的 `w600k_mbf.onnx`，转换后约 13MB CoreML；
- **权重为非商用研究许可**，不随 App / 仓库分发；
- 当前仅建议内部验证；对外发布前需取得商业授权或替换为 SeetaFace6 / SFace 等可商用模型。

> 人物检索默认关闭。没有模型时 App 仍可正常搜索，只显示“人物模型未安装”；不会阻塞文件名、正文、OCR 或语义搜索。

### 2.2 下载地址

官方 `buffalo_sc.zip`：

<https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip>

SHA-256（官方 release 资产）：

```text
57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72
```

模型包很小（约 14.3MB），包含检测模型 `det_500m.onnx` 与识别模型 `w600k_mbf.onnx`。App 只用 `w600k_mbf.onnx` 做识别；检测与五点对齐由 macOS Vision 完成。

```bash
curl -L -o buffalo_sc.zip \
  https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip

shasum -a 256 buffalo_sc.zip
# 应等于上面的 SHA-256

unzip buffalo_sc.zip -d buffalo_sc
ls buffalo_sc
# 应看到 det_500m.onnx、w600k_mbf.onnx
```

### 2.3 转换为 CoreML

App 读取的是编译后的 `buffalo_sc.mlmodelc`，不是 ONNX。仓库提供转换脚本；需要 macOS + Xcode 的 CoreML 编译器。

> `coremltools 5.2` 是旧版转换器（脚本使用的是 `ct.converters.onnx`）。建议用 Python 3.10 建独立 venv；如果系统 Python 较新导致安装失败，先换 Python 3.10，不要改用 coremltools 6+ 的 API。

```bash
python3 -m venv ~/.astfind/face/.venv
~/.astfind/face/.venv/bin/pip install coremltools==5.2 onnx numpy

~/.astfind/face/.venv/bin/python \
  AstfindKit/scripts/face/convert_buffalo_sc.py \
  buffalo_sc/w600k_mbf.onnx buffalo_sc.mlmodel

# 编译为 App 读取的 .mlmodelc
xcrun coremlcompiler compile buffalo_sc.mlmodel .

mkdir -p "$HOME/Library/Application Support/Astfind/models"
cp -R buffalo_sc.mlmodelc \
  "$HOME/Library/Application Support/Astfind/models/"
```

最终路径必须精确为：

```text
~/Library/Application Support/Astfind/models/buffalo_sc.mlmodelc
```

> 不要把模型权重提交到仓库；`.gitignore` 已忽略构建产物，但模型目录本身也不应进入 Git。

### 2.4 在 App 中配置

1. 打开 **设置 → 统一搜索来源**；
2. 展开目标来源，打开 **人物检索**；
3. 第一次开启会下载/加载模型并确认索引范围（来源内目录或整个来源）；
4. 默认关闭；按来源开启，人脸向量独立存储，可随时删除；
5. 在搜索面板选择「按人物照片找人」，给一张清晰的参考照片；
6. 合影有多张脸时，从候选脸中选择主脸再查。

CLI 验证：

```bash
astfind-sources face status
# 预期 model: ready；同时打印 model path

astfind-sources face detect /path/to/reference.jpg
astfind-sources face search /path/to/reference.jpg
```

如果状态仍是 `model: missing`：

- 检查路径是否包含 `buffalo_sc.mlmodelc` 目录；
- 检查目录内是否有 `coremldata.bin` / 编译产物；
- 确认 App 已重启，或重新打开人物检索；
- 确认模型不是损坏的 ONNX 文件直接改后缀。

### 2.5 许可提醒

`buffalo_sc` 权重为非商用研究许可。模型可下载不等于获得商用授权；公开分发、商业发布或对外服务前，必须完成许可审查或替换模型。详见 [人物检索设计备忘](person-search-design.md) §6。

---

## 三、模型与仓库的边界

- App 不打包模型权重，也不自动下载 / 自动转换；
- 仓库不包含 `*.mlmodelc`、ONNX 权重或真实索引；
- 模型缺省时对应功能显示“未安装”，不影响基础搜索；
- 远程语义模式不需要下载本机 WeMM-2B，但仍需显式授权外发；
- 两个模型的下载地址、许可证与配置步骤以本文为准；模型卡更新时以官方页面为准。
