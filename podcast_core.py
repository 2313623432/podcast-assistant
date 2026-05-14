"""Chunking, dialogue parsing, MP3 merge, and SRT timing."""

from __future__ import annotations

import io
import os
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from pydub import AudioSegment

from volcano_tts import TtsSpeechStyle, synthesize_mp3


def _configure_packaged_ffmpeg() -> None:
    """Prefer ffmpeg bundled beside the packaged executable."""
    candidates = []
    env_ffmpeg = os.environ.get("FFMPEG_BINARY")
    env_ffprobe = os.environ.get("FFPROBE_BINARY")
    if env_ffmpeg and env_ffprobe:
        candidates.append((Path(env_ffmpeg), Path(env_ffprobe)))

    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
    candidates.append((base / "vendor" / "ffmpeg" / "bin" / "ffmpeg.exe", base / "vendor" / "ffmpeg" / "bin" / "ffprobe.exe"))
    candidates.append((Path(__file__).resolve().parent / "vendor" / "ffmpeg" / "bin" / "ffmpeg.exe", Path(__file__).resolve().parent / "vendor" / "ffmpeg" / "bin" / "ffprobe.exe"))

    for ffmpeg, ffprobe in candidates:
        if ffmpeg.exists() and ffprobe.exists():
            AudioSegment.converter = str(ffmpeg)
            AudioSegment.ffmpeg = str(ffmpeg)
            AudioSegment.ffprobe = str(ffprobe)
            os.environ["PATH"] = str(ffmpeg.parent) + os.pathsep + os.environ.get("PATH", "")
            return


_configure_packaged_ffmpeg()

# 火山单次不宜过长；按字切分（用户提到约 500，这里保守）
DEFAULT_MAX_CHARS = 450
# UTF-8 上限兜底（字节）
DEFAULT_MAX_BYTES = 1000


def chunk_text(
    text: str,
    max_chars: int | None = None,
    max_bytes: int | None = None,
) -> list[str]:
    """Split long text into provider-safe pieces, preferring sentence boundaries."""
    if max_chars is None:
        max_chars = DEFAULT_MAX_CHARS
    if max_bytes is None:
        max_bytes = DEFAULT_MAX_BYTES
    text = text.strip()
    if not text:
        return []

    def fits_piece(s: str) -> bool:
        if len(s) > max_chars:
            return False
        if len(s.encode("utf-8")) > max_bytes:
            return False
        return True

    def hard_split(s: str) -> list[str]:
        out: list[str] = []
        cur = ""
        for ch in s:
            cand = cur + ch
            if len(cand) > max_chars or len(cand.encode("utf-8")) > max_bytes:
                if cur:
                    out.append(cur)
                cur = ch
            else:
                cur = cand
        if cur:
            out.append(cur)
        return out

    if fits_piece(text):
        return [text]

    # 按句号类切分后合并成块
    pieces: list[str] = []
    buf = ""
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        buf += ch
        if ch in "。！？\n" or i == n - 1:
            seg = buf.strip()
            buf = ""
            if seg:
                pieces.append(seg)
        i += 1
    if buf.strip():
        pieces.append(buf.strip())

    chunks: list[str] = []
    cur = ""
    for seg in pieces:
        if not seg:
            continue
        merged = (cur + seg).strip()
        if fits_piece(merged):
            cur = merged
        else:
            if cur:
                chunks.append(cur)
            cur = ""
            if fits_piece(seg):
                cur = seg
            else:
                for h in hard_split(seg):
                    chunks.append(h)
    if cur:
        chunks.append(cur)
    return [c for c in chunks if c.strip()]


@dataclass
class Utterance:
    speaker: str
    text: str
    display_line: str


def single_mode_blocks(script: str) -> list[Utterance]:
    """单人模式：空行分段；无空行则整段一条。"""
    s = script.strip()
    if not s:
        return []
    blocks = re.split(r"\n\s*\n+", s)
    out: list[Utterance] = []
    for b in blocks:
        t = " ".join(line.strip() for line in b.splitlines() if line.strip())
        if t:
            out.append(Utterance(speaker="", text=t, display_line=t))
    return out


def parse_speaker_alias_lines(text: str) -> dict[str, str]:
    """
    每行一条：男=大刘 或 男,大刘（支持中文逗号）。
    以 # 开头的行为注释。
    """
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        sep: str | None = None
        for s in ("=", "＝", ",", "，"):
            if s in line:
                sep = s
                break
        if sep is None:
            continue
        k, v = line.split(sep, 1)
        k, v = k.strip(), v.strip()
        if k and v:
            out[k] = v
    return out


def apply_speaker_aliases(
    utterances: list[Utterance], aliases: dict[str, str]
) -> list[Utterance]:
    """把对白里的称呼（如 男）换成显示名（如 大刘），用于音色匹配与字幕。"""
    if not aliases:
        return utterances
    return [_utterance_with_alias(u, aliases) for u in utterances]


def _utterance_with_alias(u: Utterance, aliases: dict[str, str]) -> Utterance:
    raw = u.speaker.strip()
    if not raw:
        return u
    canon = aliases.get(raw, raw)
    if canon == raw:
        return u
    new_display = f"{canon}：{u.text}" if u.text else f"{canon}："
    return Utterance(speaker=canon, text=u.text, display_line=new_display)


def parse_dialogue(script: str) -> list[Utterance]:
    """
    Lines like: 大刘：你好
    Full-width colon ： or half-width : after speaker name.
    Non-matching lines append to previous utterance.
    """
    lines = script.splitlines()
    out: list[Utterance] = []
    pat = re.compile(r"^([^：:]+)[：:]\s*(.*)$")
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        m = pat.match(line)
        if m:
            sp = m.group(1).strip()
            rest = m.group(2).strip()
            display = f"{sp}：{rest}" if rest else f"{sp}："
            out.append(Utterance(speaker=sp, text=rest, display_line=display))
        elif out:
            prev = out[-1]
            merged_text = (prev.text + line).strip()
            merged_display = f"{prev.speaker}：{merged_text}"
            out[-1] = Utterance(
                speaker=prev.speaker,
                text=merged_text,
                display_line=merged_display,
            )
        else:
            out.append(Utterance(speaker="", text=line, display_line=line))
    return out


def _segment_from_mp3(data: bytes) -> AudioSegment:
    return AudioSegment.from_mp3(io.BytesIO(data))


def ms_to_srt_time(ms: int) -> str:
    if ms < 0:
        ms = 0
    h = ms // 3600000
    m = (ms % 3600000) // 60000
    s = (ms % 60000) // 1000
    ms_rem = ms % 1000
    return f"{h:02d}:{m:02d}:{s:02d},{ms_rem:03d}"


# 手机竖屏：每条字幕不宜过长；时间过短会看不清
DEFAULT_SUBTITLE_MAX_CUE_CHARS = 26
DEFAULT_SUBTITLE_LINE_CHARS = 13
MIN_SUBTITLE_DURATION_MS = 520


def _piece_subtitle_timeline(
    piece: str,
    dur_ms: int,
    max_cue_chars: int,
) -> list[tuple[int, int, int]]:
    """
    在「单次 TTS 返回的这一段」内切字幕，并把该段真实时长 dur_ms 按字数比例切开。
    段与段之间时间与拼接后的 MP3 严格对齐；语速 speed_ratio 已体现在 dur_ms 中。
    返回 (字符起始, 字符结束, 该条时长 ms)，时长之和等于 dur_ms。
    """
    if dur_ms <= 0:
        return []
    spans = split_subtitle_spans(piece, max_cue_chars=max_cue_chars)
    if not spans:
        return [(0, len(piece), dur_ms)]
    weights = [max(1, b - a) for a, b in spans]
    tw = sum(weights)
    times: list[int] = []
    allocated = 0
    for i in range(len(spans) - 1):
        w = weights[i]
        t = max(1, int(dur_ms * w / tw))
        times.append(t)
        allocated += t
    times.append(max(1, dur_ms - allocated))
    drift = dur_ms - sum(times)
    if drift != 0:
        times[-1] = max(1, times[-1] + drift)
    return [(a, b, t) for (a, b), t in zip(spans, times, strict=True)]


def split_subtitle_spans(
    text: str,
    *,
    max_cue_chars: int = DEFAULT_SUBTITLE_MAX_CUE_CHARS,
) -> list[tuple[int, int]]:
    """
    Split into half-open [start, end) indices for mobile-friendly cues.
    Prefers 。！？… then ，、； then hard wrap.
    """
    t = text.strip()
    if not t:
        return []
    n = len(t)
    punct_major = "。！？…"
    punct_minor = "，、；,"

    def break_hard(a: int, limit_end: int) -> int:
        """First segment end in (a, limit_end], prefer punctuation near max_cue."""
        cap = min(a + max_cue_chars, limit_end)
        if cap >= limit_end:
            return limit_end
        for j in range(cap - 1, a, -1):
            if t[j - 1] in punct_major + punct_minor:
                return j
        return cap

    spans: list[tuple[int, int]] = []
    i = 0
    while i < n:
        if t[i].isspace():
            i += 1
            continue
        j = i
        while j < n and t[j] not in punct_major:
            j += 1
        if j < n and t[j] in punct_major:
            j += 1
        seg_end = j
        p = i
        while p < seg_end:
            nxt = break_hard(p, seg_end)
            if nxt <= p:
                nxt = min(p + max_cue_chars, seg_end)
            spans.append((p, nxt))
            p = nxt
        i = seg_end

    merged: list[tuple[int, int]] = []
    for a, b in spans:
        if b <= a:
            continue
        if merged and (b - a) < 5 and a == merged[-1][1]:
            pa, _pb = merged[-1]
            merged[-1] = (pa, b)
            continue
        merged.append((a, b))
    return merged


def _wrap_subtitle_lines(body: str, line_max: int) -> str:
    body = body.strip()
    if not body:
        return body
    if len(body) <= line_max:
        return body
    lines: list[str] = []
    i = 0
    while i < len(body):
        lines.append(body[i : i + line_max])
        i += line_max
    return "\n".join(lines)


def _format_srt_cue_text(
    speaker: str,
    body: str,
    *,
    show_speaker: bool,
    line_max: int,
) -> str:
    wrapped = _wrap_subtitle_lines(body, line_max)
    if show_speaker and speaker:
        if "\n" in wrapped:
            return f"{speaker}：\n{wrapped}"
        if len(speaker) + 1 + len(wrapped) <= line_max * 2:
            return f"{speaker}：{wrapped}"
        return f"{speaker}：\n{wrapped}"
    return wrapped


def build_podcast_audio_srt(
    appid: str,
    token: str,
    utterances: list[Utterance],
    voice_for_speaker: Callable[[str], str],
    *,
    pause_between_ms: int = 350,
    chunk_max_chars: int = DEFAULT_MAX_CHARS,
    chunk_max_bytes: int = DEFAULT_MAX_BYTES,
    subtitle_max_cue_chars: int = DEFAULT_SUBTITLE_MAX_CUE_CHARS,
    subtitle_line_chars: int = DEFAULT_SUBTITLE_LINE_CHARS,
    min_subtitle_ms: int = MIN_SUBTITLE_DURATION_MS,
    speech_style: TtsSpeechStyle | None = None,
    progress_cb: Callable[[int, int, str], None] | None = None,
) -> tuple[bytes, str]:
    """
    voice_for_speaker(speaker: str) -> voice_type str
    progress_cb(done: int, total: int, label: str)
    """
    combined = AudioSegment.silent(duration=0)
    srt_blocks: list[str] = []
    cue_index = 1
    t_ms = 0

    total_units = 0
    for u in utterances:
        if u.text.strip():
            total_units += len(
                chunk_text(u.text, max_chars=chunk_max_chars, max_bytes=chunk_max_bytes)
            )
    if total_units == 0:
        total_units = 1
    done_units = 0

    for utt in utterances:
        if not utt.text.strip():
            continue
        voice = voice_for_speaker(utt.speaker)
        chunks = chunk_text(
            utt.text, max_chars=chunk_max_chars, max_bytes=chunk_max_bytes
        )
        line_audio = AudioSegment.silent(duration=0)
        pieces_duration: list[tuple[str, int]] = []
        for piece in chunks:
            if progress_cb:
                progress_cb(done_units, total_units, piece[:24] + ("…" if len(piece) > 24 else ""))
            mp3 = synthesize_mp3(
                appid, token, piece, voice, style=speech_style
            )
            if mp3:
                seg = _segment_from_mp3(mp3)
                pieces_duration.append((piece, len(seg)))
                line_audio += seg
            done_units += 1

        utt_ms = len(line_audio)
        utterance_start_ms = t_ms
        utterance_end = utterance_start_ms + utt_ms
        spk = utt.speaker.strip()

        # 时间轴：每个 TTS 分段的时长来自真实 MP3（已含语速），段界精确对齐；
        # 段内再按字数比例拆多条字幕，误差只发生在单段内、不再跨段累积。
        timeline_ms = 0
        first_cue_in_utt = True
        utt_cues: list[tuple[int, int, str]] = []
        for piece, dur_ms in pieces_duration:
            for a, b, tseg in _piece_subtitle_timeline(
                piece, dur_ms, subtitle_max_cue_chars
            ):
                body = piece[a:b].strip()
                if not body:
                    timeline_ms += tseg
                    continue
                start_ms = utterance_start_ms + timeline_ms
                end_ms = start_ms + tseg
                timeline_ms += tseg
                if end_ms <= start_ms:
                    end_ms = start_ms + 1
                show_sp = first_cue_in_utt and bool(spk)
                first_cue_in_utt = False
                cue_text = _format_srt_cue_text(
                    spk,
                    body,
                    show_speaker=show_sp,
                    line_max=subtitle_line_chars,
                )
                utt_cues.append((start_ms, end_ms, cue_text))

        if utt_cues:
            last_end = utt_cues[-1][1]
            drift = utterance_end - last_end
            if drift > 1:
                ls, le, ctxt = utt_cues[-1]
                utt_cues[-1] = (ls, min(le + drift, utterance_end), ctxt)
            ls, le, ctxt = utt_cues[-1]
            le = max(le, min(ls + min_subtitle_ms, utterance_end))
            if le <= ls:
                le = min(ls + 1, utterance_end)
            utt_cues[-1] = (ls, le, ctxt)

        for start_ms, end_ms, cue_text in utt_cues:
            srt_blocks.append(
                f"{cue_index}\n"
                f"{ms_to_srt_time(start_ms)} --> {ms_to_srt_time(end_ms)}\n"
                f"{cue_text}\n"
            )
            cue_index += 1

        combined += line_audio
        if pause_between_ms > 0:
            combined += AudioSegment.silent(duration=pause_between_ms)
            t_ms = utterance_end + pause_between_ms
        else:
            t_ms = utterance_end

    out_buf = io.BytesIO()
    combined.export(out_buf, format="mp3", bitrate="192k")
    srt_text = "\n".join(srt_blocks)
    return out_buf.getvalue(), srt_text
