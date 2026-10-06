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

### 下载模型（HuggingFace / ModelScope / HF 镜像）

```swift
import MinerUKit

// App 的自然入口：下载（或复用已完成的下载）后直接加载
let session = try await MinerUKit.Session.load(
    source: .recommended,                      // 已验证可用的 8bit 转换（1.85GB）
    in: appSupport.appendingPathComponent("MinerU-8bit")
) { p in
    progressBar.doubleValue = p.fraction       // 0…1，含文件名/序号/字节数
}
let markdown = try await session.convert(pdfURL: url)
```

也可单独下载：

```swift
let dir = try await ModelStore.download(.recommended, to: destination) { p in … }
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

### 命令行

```bash
swift run -c release minerukit download --recommended --to ~/models/mineru-8bit
swift run -c release minerukit convert --pdf paper.pdf --model ~/models/mineru-8bit --out paper.md
# 其他镜像：
swift run -c release minerukit download --repo OpenGryd/MinerU2.5-Pro-2605-1.2B-MLX-8bit \
    --mirror hf-mirror --to ~/models/mineru-8bit
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
  含精确去重与 IoU 重叠抑制（≥85% 包含于 table/figure 等容器块的区块会被丢弃）
- `TableMarkdown.convert(_:)` — MinerU 表格标记（`<fcel>/<nl>/<lcel>/<ucel>/<ecel>`）→ GFM 表格
- `NoRepeatNGramProcessor` — 反复读 logits processor（MinerU vLLM 实现的移植）

## 测试

```bash
swift test    # 33 个纯逻辑单测，不需要模型/Metal 设备
```

## 已知限制

- 模型需 Apple Silicon（MLX/GPU），建议 ≥8GB 内存
- 视觉像素预算默认对齐模型 preprocessor config（`maxPixels: 1_605_632`）；
  不要删掉这个覆盖——mlx-swift-lm 默认把预算钳制在 `1280×28×28`，会把 1036² 页面静默缩小，
  导致版面识别退化（实测踩坑）
- 1.2B 4bit 对小字号有轻微 OCR 误差；重复循环由内置 NoRepeatNGram(100) + presence penalty 抑制
- Markdown 表格不支持 colspan/rowspan，合并单元格以空列展开
