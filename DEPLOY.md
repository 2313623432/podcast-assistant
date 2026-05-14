# 部署说明

合成与字幕依赖 **ffmpeg**（pydub 处理 MP3），云端必须能调用到 `ffmpeg`。

---

## 方式一：Streamlit Community Cloud（免费，适合个人）

1. 把本项目推到 **GitHub** 公开或私有仓库。
2. 打开 [share.streamlit.io](https://share.streamlit.io) ，用 GitHub 登录，**New app**。
3. 选择仓库、分支，**Main file** 填：`app.py`。
4. **Advanced settings** → **Secrets**，粘贴（换成你的真实值）：

   ```toml
   VOLCANO_TTS_APP_ID = "xxx"
   VOLCANO_TTS_ACCESS_TOKEN = "xxx"
   ```

5. 仓库根目录已有 **`packages.txt`**（内容为 `ffmpeg`），构建时会自动安装系统里的 ffmpeg。
6. Deploy。首次构建可能要几分钟。

**注意**：免费版有资源与休眠限制；长文案合成可能超时，可尝试调小「单次合成最大字数」。

---

## 方式二：Docker（自建 / Railway / Fly.io / 云主机）

```bash
docker build -t podcast-assistant .
docker run -p 8501:8501 \
  -e VOLCANO_TTS_APP_ID=你的AppId \
  -e VOLCANO_TTS_ACCESS_TOKEN=你的Token \
  podcast-assistant
```

部分平台会注入 **`PORT`** 环境变量，镜像入口脚本已支持 `${PORT:-8501}`。

---

## 凭证从哪里读

| 环境 | 说明 |
|------|------|
| 本地 | **侧栏输入框**（默认）、或 `.env` / 环境变量；**不必**建 `secrets.toml` |
| Streamlit Cloud | **Secrets**（同上两个键名） |
| Docker / K8s | `-e` 或编排里设置环境变量 |

**不要把真实 Token 提交到 Git。**

---

## 可选：本地验证 Docker

```bash
docker build -t podcast-assistant .
docker run --rm -p 8501:8501 --env-file .env podcast-assistant
```

浏览器访问 `http://localhost:8501`。
