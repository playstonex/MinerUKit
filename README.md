# MinerUKit

MinerU2.5-Pro（Qwen2-VL 1.2B）文档解析管线的纯 Swift 实现，基于
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 在 Apple Silicon 上本地推理。

PDF → 两阶段协议（1036² 版面检测 → 逐区域识别）→ Markdown（含 GFM 表格、LaTeX 公式、图片引用）。
无 Python、无 WebView、无网络依赖（模型本地加载）。

## 接入

Xcode：**File → Add Package Dependencies → Add Local…** 选择本目录，
把 `MinerUKit` 产品加到 target。

Swift Package Manager：

```swift
.package(path: "../MinerUKit")  // 或 file:/绝对路径 / git URL
```

## 使用

### 四个解析档位

```swift
var options = MinerUKit.Options()
options.tier = .flash      // 或 .basic / .standard（默认）/ .advanced
```

| 档位 | 有文本层的页 | 扫描页/图片页 | 模型 | 实测 15 页论文 |
|---|---|---|---|---|
| `flash` | 原生文本抽取 | 占位提示 | **不加载** | **1.2 秒** |
| `basic` | 原生文本抽取 | 回退 VLM 两阶段 | 按需 | 1.0 秒（全有文本层时） |
| `standard` | VLM 两阶段 | 同左 | 全页 | ~16 分钟 |
| `advanced` | 两阶段 + 288dpi + 更大识别预算 | 同左 | 全页 | 更慢 |

- 文本层抽取带段落重组（断字合并、CJK 无空格连接、列表独立成块），
  文字零 OCR 误差；无标题层级/公式 LaTeX/表格结构（版面信息只有 VLM 档才有）
- `flash` 档 `modelDir` 参数被忽略，`MinerUKit.convert` 直接跳过模型加载
- `basic` 是混合模式：逐页检测文本密度（≥32 字符），够稠密走快速通道，
  稀疏（扫描件）才落回 VLM——扫描件与文字档混合的文档性价比最高

### 下载模型（HuggingFace / ModelScope / HF 镜像）

```swift
import MinerUKit

// App 的自然入口：下载（或复用已完成的下载）后直接加载
let session = try await MinerUKit.Session.load(
    source: .recommended.with(token: hfToken), // 默认 playstonex/MinerU2.5-Pro-2605-1.2B-mlx-4bit（约 1.7GB）
    in: appSupport.appendingPathComponent("MinerU")
) { p in
    progressBar.doubleValue = p.fraction       // 0…1，含文件名/序号/字节数
}
let markdown = try await session.convert(pdfURL: url)
```

也可单独下载：

```swift
let dir = try await ModelStore.download(.recommended, to: destination) { p in … }
```

**默认仓库是 gated 仓库**：需先在[模型页](https://huggingface.co/playstonex/MinerU2.5-Pro-2605-1.2B-mlx-4bit)
登录并接受条款，再提供 HF 访问令牌（read 权限）。未授权时抛 `ModelStore.Error.authenticationRequired`。
令牌来源：`Source.token` / CLI `--token` / 环境变量 `HF_TOKEN`、`HUGGING_FACE_HUB_TOKEN` /
`~/.cache/huggingface/token`（仅对 huggingface.co 读取环境令牌；令牌只发往同主机的 https 请求，
重定向到其他主机时自动去掉）。

指定其他地址——`Source.parse` 接受 `owner/name`、模型页 URL（含 `/tree/<rev>`、`/resolve/<rev>/…`）、
任意 HF 兼容主机或 modelscope.cn：

```swift
let src = try ModelStore.Source.parse("https://hf-mirror.com/OpenGryd/MinerU2.5-Pro-2605-1.2B-MLX-8bit")
```

来源工厂：

```swift
.huggingFace("OpenGryd/MinerU2.5-Pro-2605-1.2B-MLX-8bit")   // huggingface.co
.hfMirror("OpenGryd/…")                                     // hf-mirror.com（HF 兼容镜像）
.modelScope("OpenDataLab/…")                                // modelscope.cn（注意：官方仓是
                                                             //  原始 HF 格式，需自行转换后才能加载）
.custom("org/model", base: URL(string: "https://your-mirror.example.com")!)
```

特性：断点续传（已存在且大小一致的文件自动跳过）、按文件校验大小、
Task 取消、SSRF 防护（仅 http/https，拒绝 localhost/环回/私有/保留地址，
**重定向跳转同样校验**）。

下载进度 `Progress` 除 `fraction` 外还带速度与预估剩余时间，便于做进度条：

```swift
let dir = try await ModelStore.download(.recommended, to: destination) { p in
    bar.doubleValue = p.fraction                       // 0…1
    label.stringValue = p.progressDescription          // "420 MB / 1.7 GB"
    speed.stringValue = ModelStore.Progress.formatBytes(Int64(p.bytesPerSecond)) + "/s"
    if let eta = p.estimatedTimeRemaining { … }        // 秒；无法估计时为 nil
}
```

### 管理已下载的模型（查看 / 校验 / 删除）

下载完成后会在模型目录根部写入 `.minerukit-manifest.json`（来源 repo/revision/base
与文件清单含大小、可用时的 sha256），后续的查看、列举、校验**全程离线**，不再联网。

```swift
// 状态：notInstalled / partial / complete（按清单逐文件核对大小；无清单时退回
// config.json + *.safetensors 结构判断）
switch ModelStore.installState(at: modelDir) {
case .complete:     // 可直接加载
case .partial:      // 下过一半，再次 download 会续传
case .notInstalled: // 该目录不是模型
}
ModelStore.isInstalled(at: modelDir)        // == .complete

// 占用磁盘字节（递归）；~1.7GB，适合在设置页显示“清理”
let bytes = ModelStore.diskUsage(at: modelDir)

// 列举某根目录下所有已安装模型（扫描直接子目录，带状态/占用/清单）
for m in ModelStore.installedModels(in: modelsRoot) {
    print(m.directory.lastPathComponent, m.state, m.diskUsage, m.manifest?.repo ?? "")
}

// 完整性校验：逐文件核对大小，清单记录了 sha256 的（HF LFS 权重）再校 sha256。
// 需要清单；损坏时抛 sizeMismatch / checksumMismatch，可据此提示用户重下。
try ModelStore.verify(at: modelDir)

// 删除整个模型目录（不存在时为 no-op）
try ModelStore.remove(at: modelDir)
```

`Session.load(source:in:)` 默认带**离线快路径**：目录已是 `complete` 时跳过联网列目录、
直接从磁盘加载——首次下载成功后 App 可离线启动。需要每次都回源校验时传
`allowOfflineReuse: false`（仍是断点续传）。

### 命令行

```bash
HF_TOKEN=hf_xxx swift run -c release minerukit download --recommended --to ~/models/mineru-4bit
swift run -c release minerukit convert --pdf paper.pdf --model ~/models/mineru-4bit --out paper.md
# 其他地址（owner/name 或 URL）、镜像、显式令牌：
swift run -c release minerukit download --repo OpenGryd/MinerU2.5-Pro-2605-1.2B-MLX-8bit \
    --mirror hf-mirror --to ~/models/mineru-8bit
swift run -c release minerukit download --repo https://hf-mirror.com/owner/name --token hf_xxx --to ~/models/x
```

### 一次性转换（每次调用加载模型）

```swift
import MinerUKit

let markdown = try await MinerUKit.convert(
    pdfURL: pdfUrl,
    modelDir: modelDirectory,          // MLX 转换产物目录（config.json + *.safetensors）
    options: .standard,
    progress: { line in print(line) }  // 进度回调（每页/每区块）
)
```

### 复用模型（推荐：多文档场景只加载一次 ~1.6GB 权重）

```swift
let session = try await MinerUKit.Session(modelDir: modelDirectory)
let md1 = try await session.convert(pdfURL: firstPdf)
let md2 = try await session.convert(pdfURL: secondPdf)
```

`Session` 是 `Sendable`，可并发调用（各自使用独立临时文件），共享 GPU 吞吐。

### 取消

`convert` 在页与区块边界检查 `Task` 取消，抛出 `CancellationError`：

```swift
let task = Task { try await session.convert(pdfURL: url, modelDir: dir) }
task.cancel()   // 最近的区块边界即停止
```

### Options

```swift
var options = MinerUKit.Options.standard
options.maxPages = 5                              // 只转前 5 页
options.imageOutputDirectory = outputDir          // 图片裁剪落盘目录（默认系统 temp，会被 OS 清理）
options.prompts["caption"] = "\nText Recognition:"  // 扩展区块类型
options.skipTypes.formUnion(["watermark"])        // 追加忽略类型
options.dumpDirectory = URL(fileURLWithPath: "/tmp")  // 调试：转储版面图与原始输出
```

所有分类表（prompts / imageTypes / skipTypes）都在 `Options` 值里，无全局状态。

## 模型

`modelDir` 指向 mlx_vlm 转换的 4bit 模型，例如：

```bash
pip install mlx-vlm
python - <<'EOF'
import mlx.core as mx
# MinerU2.5-Pro 为 tied embeddings，需先显式补 lm_head 再转换
w = mx.load('model.safetensors', format='safetensors')
w['lm_head.weight'] = w['model.embed_tokens.weight']
mx.save_safetensors('hf_patched/model.safetensors', w)  # 注意：用相对路径（部分外置卷上绝对路径会失败）
EOF
mlx_vlm convert --hf-path hf_patched --mlx-path MinerU2.5-Pro-mlx-4bit \
    --quantize --q-bits 4 --q-group-size 64
# 若 config.json 缺 quantization 字段，手工补：
# {"quantization": {"group_size": 64, "bits": 4, "mode": "affine"}}
```

模型权重：[opendatalab/MinerU2.5-Pro-2605-1.2B](https://huggingface.co/opendatalab/MinerU2.5-Pro-2605-1.2B)（Apache-2.0）。

## 单独使用子模块

- `LayoutParser.parse(_:)` — MinerU 版面输出（`<|box_start|>…<|ref_start|>…`）解析，
  与 mineru-vl-utils 2.0 一致：同类型同方向 IoU>0.9 去重、≥90% 被 table/image 覆盖的区块丢弃、
  识别 `txt_contd_tgt`（跨栏/跨页续段）
- `TableMarkdown.convert(_:)` — MinerU 表格标记（`<fcel>/<nl>/<lcel>/<ucel>/<ecel>`）→ GFM 表格
- `NoRepeatNGramProcessor` — 反复读 logits processor（MinerU vLLM 实现的移植）

## 测试

```bash
swift test    # 103 个纯逻辑单测，不需要模型/Metal 设备
```

## 安全说明（下载）

- 所有请求仅允许 http/https；拒绝 localhost、`.local`/`.internal`、环回/私有/链路本地/
  保留地址（含 169.254.169.254 元数据端点）与保留 IPv6 段；**重定向每一跳重新校验**
- LFS 文件按 HF 提供的 sha256 逐字节校验（流式，1 MiB 分块）；校验失败不重试（确定性错误）
- 瞬时网络错误按 1s/2s/4s/8s 退避重试，共 5 次尝试；`Task` 取消随时生效
- 已知边界：主机名校验不防 DNS 重绑定（域名解析到私网 IP 会放行）。
  对"用户自选镜像"的场景这是接受的取舍；高安全场景应在调用方再做解析后 IP 校验

## 与 MinerU 官方管线的对齐情况

已对齐 mineru-vl-utils 2.0.7（`mineru_client.py` / `post_process/`）：

- 采样：presence 1.0 + frequency（table 0.005，其余 0.05）+ NoRepeatNGram(100)
- 版面：IoU 去重、表内/图内覆盖过滤、`unknown→image`、`list`/`equation_block`/`image_block` 容器不直接识别
- 区块图：不加边距；长宽比 >50 用白边补齐，短边 <28 放大；旋转方向为 PIL 逆时针（right=90、down=180、left=270）
- 后处理：`[Non-Text]` 占位丢弃；公式修复链（`\left/\right` 配平、双下标、`\coloneqq`、`\big{)}`、`<`、花括号配平）；
  `equation_block` 合并；正文 `\[x\]→\(x\)`、宏后补空格、下划线移出公式；`txt_contd_tgt` 续段合并
- 公式 token 间空格清理（`LatexCleaner`）为本包额外增加，官方不做；行间公式默认用 `$$…$$`
  （`Options.displayMath = .brackets` 可切回官方的 `\[…\]`）
- 原生文本层：移除 CJK 字符间的生成空格

## 与 MinerU 官方管线的已知差异

- 无跨页表格合并（官方 `cross_page_table_merge`）
- 官方 standard 档把 PDF 文本层与 VLM 混合在区块级融合；本包的 `basic` 档是页级混合
  （整页要么文本要么 VLM），尚未做区块级融合
- 无图表/图片内容分析（`image_analysis` 默认关闭，图片以裁剪图嵌入）与 `formula_number` 合并
- 无超长/超宽页窗口切分（固定 1036²，A3/拼版页会挤压）
- Markdown 表格不支持 colspan/rowspan，合并单元格以空列展开（官方转 HTML 表格）

## 已知限制

- 模型需 Apple Silicon（MLX/GPU），建议 ≥8GB 内存
- 视觉像素预算默认对齐模型 preprocessor config（`maxPixels: 1_605_632`）；
  不要删掉这个覆盖——mlx-swift-lm 默认把预算钳制在 `1280×28×28`，会把 1036² 页面静默缩小，
  导致版面识别退化（实测踩坑）
- 1.2B 量化模型对小字号有轻微 OCR 误差；重复循环由内置 NoRepeatNGram(100) + presence penalty 抑制
