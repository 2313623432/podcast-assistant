"""播客助手：单人 / 双人模式，火山 TTS，导出 MP3 + SRT。"""

from __future__ import annotations

import os
from datetime import datetime

import streamlit as st
from dotenv import load_dotenv

from podcast_core import (
    apply_speaker_aliases,
    build_podcast_audio_srt,
    parse_dialogue,
    parse_speaker_alias_lines,
    single_mode_blocks,
)
from volcano_tts import TtsSpeechStyle

load_dotenv()

SESSION_AUDIO = "podcast_audio_bytes"
SESSION_SRT = "podcast_srt_text"
SESSION_TS = "podcast_export_ts"

# 折叠区里的 slider 若未初始化，曾与 key 混用导致状态异常；统一先写入默认值
_W_DEFAULTS: dict[str, float | int | str] = {
    "_pitch_ratio": 1.0,
    "_volume_ratio": 1.0,
    "_lang_choice": "不设置",
    "_emo_choice": "不设置",
    "_srt_cue_max": 26,
    "_srt_line_max": 13,
    "_srt_min_ms": 520,
}


def _ensure_widget_defaults() -> None:
    for k, v in _W_DEFAULTS.items():
        if k not in st.session_state:
            st.session_state[k] = v


def _get_env() -> tuple[str, str]:
    """优先环境变量 / .env；若部署在 Streamlit Cloud 且未配 env，再读 st.secrets。
    本地没有 secrets.toml 时，访问 st.secrets 会抛 StreamlitSecretNotFoundError，必须捕获，
    否则页面在侧栏输入框渲染前就崩溃。"""
    app_id = os.environ.get("VOLCANO_TTS_APP_ID", "").strip()
    token = os.environ.get("VOLCANO_TTS_ACCESS_TOKEN", "").strip()
    try:
        sec = st.secrets
        if not app_id and "VOLCANO_TTS_APP_ID" in sec:
            app_id = str(sec["VOLCANO_TTS_APP_ID"]).strip()
        if not token and "VOLCANO_TTS_ACCESS_TOKEN" in sec:
            token = str(sec["VOLCANO_TTS_ACCESS_TOKEN"]).strip()
    except Exception:
        pass
    return app_id, token


st.set_page_config(page_title="播客助手", layout="wide")
_ensure_widget_defaults()
st.title("播客助手")
st.caption("火山引擎语音合成 · 长文案自动切段拼接 · 导出 MP3 / SRT")

with st.sidebar:
    st.subheader("火山引擎凭证")
    st.caption("可直接在下方输入框填写，无需创建 secrets.toml；也可用项目目录里的 .env。")
    st.markdown(
        "**凭证必须来自「豆包语音」应用**：控制台 → 豆包语音 → 创建/选择应用 → 查看 **AppId** 与 **Access Token**（访问令牌）。\n\n"
        "不要用 IAM 的 AccessKey/SecretKey，也不要用其它产品里的「API Key」顶替 Token，否则会报 `grant not found` / 401。\n\n"
        "`.env` 示例：\n\n"
        "`VOLCANO_TTS_APP_ID=...`\n\n"
        "`VOLCANO_TTS_ACCESS_TOKEN=...`\n\n"
        "[API 接入 FAQ](https://www.volcengine.com/docs/6561/111522)"
    )
    env_app, env_tok = _get_env()
    app_id_in = st.text_input("App ID", value=env_app or "", type="default")
    token_in = st.text_input("Access Token（控制台密钥）", value=env_tok or "", type="password")
    app_id = app_id_in.strip() or env_app
    token = token_in.strip() or env_tok

mode = st.radio("模式", ["单人", "双人"], horizontal=True)

if mode == "单人":
    voice_single = st.text_input(
        "音色 voice_type",
        value="BV002_streaming",
        help="在火山文档音色列表中复制，例如 BV001_streaming、BV700_streaming",
    )
    auto_gender_alias = False
    alias_extra_lines = ""
else:
    c1, c2 = st.columns(2)
    with c1:
        name_a = st.text_input("角色 A 名称", value="大刘")
        voice_a = st.text_input("角色 A 音色", value="BV002_streaming")
    with c2:
        name_b = st.text_input("角色 B 名称", value="小芳")
        voice_b = st.text_input("角色 B 音色", value="BV104_streaming")
    auto_gender_alias = st.checkbox(
        "快捷：文案里「男」对角色 A、「女」对角色 B（字幕与音色均用角色名）",
        value=True,
    )
    alias_extra_lines = st.text_area(
        "更多称呼映射（可选）",
        height=72,
        placeholder="男=大刘\n女=小芳\n主持人,大刘",
        help="每行一条：称呼=显示名 或 称呼,显示名。会与上面快捷合并，此处同名会覆盖快捷。",
    )

st.subheader("合成参数")
row_syn = st.columns(3)
with row_syn[0]:
    max_chars = st.slider(
        "单次合成最大字数（建议≤500）",
        200,
        500,
        450,
        10,
        help="数值越小，每条 TTS 越短，字幕时间轴越贴近真实发音（更费请求次数）",
    )
with row_syn[1]:
    pause_ms = st.slider("句间停顿（毫秒）", 0, 1200, 350, 50)
with row_syn[2]:
    speed_ratio = st.slider(
        "语速（倍率）",
        min_value=0.3,
        max_value=2.5,
        value=1.0,
        step=0.05,
        help="对应 speed_ratio，约 0.2～3；过慢/过快部分音色可能不稳定",
    )

with st.expander("听感进阶（音高 / 音量 / 语种 / 情感）", expanded=False):
    st.caption(
        "对应 pitch_ratio、volume_ratio、language、emotion。"
        "方言请优先换「方言类音色 ID」；language / emotion 仅部分音色支持，报错请改回「不设置」。"
    )
    col_sp2, col_sp3 = st.columns(2)
    with col_sp2:
        st.slider(
            "音高（听感偏亮/偏低）",
            min_value=0.85,
            max_value=1.15,
            step=0.01,
            help="略改声线明暗，不等同方言",
            key="_pitch_ratio",
        )
    with col_sp3:
        st.slider(
            "音量（相对）",
            min_value=0.6,
            max_value=1.5,
            step=0.05,
            key="_volume_ratio",
        )
    col_sp4, col_sp5 = st.columns(2)
    with col_sp4:
        st.selectbox(
            "language（多语种音色可选）",
            ["不设置", "cn", "en", "ja"],
            key="_lang_choice",
        )
    with col_sp5:
        st.selectbox(
            "emotion（部分音色支持）",
            ["不设置", "happy", "calm", "sad", "angry"],
            key="_emo_choice",
        )

pitch_ratio = float(st.session_state.get("_pitch_ratio", 1.0))
volume_ratio = float(st.session_state.get("_volume_ratio", 1.0))
_lc = st.session_state.get("_lang_choice", "不设置")
lang_val = None if _lc == "不设置" else str(_lc)
_ec = st.session_state.get("_emo_choice", "不设置")
emo_val = None if _ec == "不设置" else str(_ec)

with st.expander("字幕排版（手机竖屏）", expanded=False):
    st.caption("按句/逗号切段，时间轴与音频对齐；过长的字会折成多行。")
    st.slider(
        "每条字幕最多字数",
        min_value=16,
        max_value=40,
        step=1,
        key="_srt_cue_max",
    )
    st.slider(
        "单行最多字数（换行用）",
        min_value=10,
        max_value=20,
        step=1,
        key="_srt_line_max",
    )
    st.slider(
        "最后一条最短显示（毫秒）",
        min_value=300,
        max_value=1200,
        step=20,
        key="_srt_min_ms",
    )

srt_cue_max = int(st.session_state.get("_srt_cue_max", 26))
srt_line_max = int(st.session_state.get("_srt_line_max", 13))
srt_min_ms = int(st.session_state.get("_srt_min_ms", 520))

script = st.text_area(
    "文案",
    height=420,
    placeholder="单人：直接输入正文，空行分段。双人：每行「角色名：台词」",
)

gen = st.button("生成音频与字幕", type="primary")

if gen:
    if not app_id or not token:
        st.error("请填写 App ID 与 Access Token（或在 .env 中配置）。")
    elif not script.strip():
        st.warning("请输入文案。")
    else:
        if mode == "单人":
            utterances = single_mode_blocks(script)

            def voice_for_speaker(_: str) -> str:
                return voice_single.strip() or "BV002_streaming"
        else:
            utterances = parse_dialogue(script)
            na, nb = name_a.strip(), name_b.strip()
            va, vb = voice_a.strip(), voice_b.strip()
            alias_merged: dict[str, str] = {}
            if auto_gender_alias:
                if na:
                    alias_merged["男"] = na
                if nb:
                    alias_merged["女"] = nb
            alias_merged.update(parse_speaker_alias_lines(alias_extra_lines))
            utterances = apply_speaker_aliases(utterances, alias_merged)

            def voice_for_speaker(sp: str) -> str:
                s = sp.strip()
                if s == na:
                    return va or "BV002_streaming"
                if s == nb:
                    return vb or "BV104_streaming"
                return va or "BV002_streaming"

        bar = st.progress(0.0, text="准备合成…")
        status = st.empty()

        def on_progress(done: int, total: int, label: str) -> None:
            bar.progress(min(1.0, done / max(total, 1)), text=f"合成中 ({done}/{total}) {label}")
            status.caption(label)

        speech_style = None
        if (
            speed_ratio != 1.0
            or pitch_ratio != 1.0
            or volume_ratio != 1.0
            or lang_val
            or emo_val
        ):
            speech_style = TtsSpeechStyle(
                speed_ratio=speed_ratio,
                pitch_ratio=pitch_ratio,
                volume_ratio=volume_ratio,
                language=lang_val,
                emotion=emo_val,
            )

        try:
            audio_bytes, srt_text = build_podcast_audio_srt(
                app_id,
                token,
                utterances,
                voice_for_speaker,
                pause_between_ms=pause_ms,
                chunk_max_chars=max_chars,
                subtitle_max_cue_chars=srt_cue_max,
                subtitle_line_chars=srt_line_max,
                min_subtitle_ms=srt_min_ms,
                speech_style=speech_style,
                progress_cb=on_progress,
            )
        except Exception as e:
            bar.empty()
            st.exception(e)
        else:
            bar.progress(1.0, text="完成")
            status.empty()
            ts = datetime.now().strftime("%Y%m%d_%H%M%S")
            st.session_state[SESSION_AUDIO] = audio_bytes
            st.session_state[SESSION_SRT] = srt_text
            st.session_state[SESSION_TS] = ts
            st.success("生成完成，可在下方预览并分别下载 MP3 与 SRT（下载不会清空结果）。")

# 下载会触发整页重跑，必须把结果放在 session_state，不能只在「生成」那一次渲染里持有
_audio = st.session_state.get(SESSION_AUDIO)
_has_audio = (
    _audio is not None
    and isinstance(_audio, (bytes, bytearray))
    and len(_audio) > 0
)
if _has_audio:
    st.divider()
    st.subheader("生成结果")
    ts = st.session_state.get(SESSION_TS) or datetime.now().strftime("%Y%m%d_%H%M%S")
    _srt = st.session_state.get(SESSION_SRT, "")
    if not isinstance(_srt, str):
        _srt = str(_srt)
    _audio_b = bytes(_audio)
    # 下载放预览上方，避免部分浏览器里大体积音频组件影响点击；数据用副本防止被改写
    cdl1, cdl2, cdl3 = st.columns([1, 1, 2])
    with cdl1:
        st.download_button(
            "下载 MP3",
            data=_audio_b,
            file_name=f"podcast_{ts}.mp3",
            mime="audio/mpeg",
            key="podcast_dl_mp3",
        )
    with cdl2:
        st.download_button(
            "下载 SRT",
            data=_srt.encode("utf-8"),
            file_name=f"podcast_{ts}.srt",
            mime="application/x-subrip",
            key="podcast_dl_srt",
        )
    with cdl3:
        if st.button("清除本次结果", key="clear_export"):
            st.session_state.pop(SESSION_AUDIO, None)
            st.session_state.pop(SESSION_SRT, None)
            st.session_state.pop(SESSION_TS, None)
            st.rerun()
    st.audio(_audio_b, format="audio/mp3")
