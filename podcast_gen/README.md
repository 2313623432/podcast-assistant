# 自动播客生成系统（Excel → TTS → MP3 + SRT + 清单）

## 依赖
- Windows（本项目使用 Excel COM 读取 xlsx，需要本机安装 Microsoft Excel）
- ffmpeg + ffprobe（用于音频拼接、重采样、立体声、码率与响度标准化）
- PowerShell 5（Windows 自带）

## 不用浏览器下载安装 ffmpeg（推荐）

如果你不想手动下载压缩包，可在 PowerShell 里运行：

```powershell
winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements
```

## 安全
- 不要把调用密钥写进配置文件或脚本
- 使用环境变量提供密钥：`BYTEDANCE_TTS_KEY`

## 配置
1. 复制配置模板：
   - `podcast_gen\config.example.json` → `podcast_gen\config.json`
2. 修改 `config.json`：
   - `tts.baseUrl`：字节跳动/火山引擎语音合成接口地址
   - `tts.appId`：若接口要求 appid，则填写；不需要可留空
   - `audio.ffmpegPath` / `audio.ffprobePath`：ffmpeg 可执行文件路径或命令名（已加入 PATH 则保持默认）

3. 设置密钥环境变量（示例）：

```powershell
$env:BYTEDANCE_TTS_KEY = '把你的密钥放这里'
```

如果你不方便设置环境变量，运行时会提示你输入密钥（输入不回显，也不会写入文件）。

## 运行

```powershell
cd D:\播客\podcast_gen
.\podcast.ps1
```

默认行为：
- 读取 `D:\播客\声音id和api.xlsx` 提取音色 ID（含小芳/大刘双人，以及所有单人主持人）
- 扫描 `D:\播客\` 下除声音表外的所有 xlsx，读取 `章节名称 / 章节内容 / 主持人`
- 对每条有效数据生成：
  - 单人版：按表格“主持人”对应音色合成
  - 双人版：将“章节内容”按句切分并交替分配给小芳/大刘（文本不改动），并在换人处插入 0.3–0.8s 停顿
- 输出：
  - MP3：44.1kHz、立体声、≥192kbps，并做 -16 LUFS 响度标准化
  - SRT：毫秒级时间轴、每行≤20汉字
  - manifest.json：记录音频时长（0.1s 精度）与元数据
  - logs/error.log：缺失字段、TTS 失败、音频处理失败等

## 输出目录
- `config.outputDir`：最终输出（mp3、srt、manifest.json）
- `config.tempDir`：中间文件（分段音频/拼接文件），可按需清理
