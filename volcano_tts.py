"""Volcano Engine (豆包语音) TTS via WebSocket binary protocol."""

from __future__ import annotations

import gzip
import json
import ssl
import struct
import uuid
from dataclasses import dataclass
from typing import Any

import websocket

WS_URL = "wss://openspeech.bytedance.com/api/v1/tts/ws_binary"
CLIENT_HEADER = bytes([0x11, 0x10, 0x11, 0x00])


@dataclass(frozen=True)
class TtsSpeechStyle:
    """火山在线语音合成 audio 层参数，见文档「参数基本说明」。"""

    speed_ratio: float = 1.0
    pitch_ratio: float = 1.0
    volume_ratio: float = 1.0
    language: str | None = None
    emotion: str | None = None


def _clampf(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


def _build_payload(
    appid: str,
    token: str,
    text: str,
    voice_type: str,
    reqid: str,
    *,
    style: TtsSpeechStyle | None = None,
) -> bytes:
    audio: dict[str, Any] = {
        "encoding": "mp3",
        "voice_type": voice_type,
    }
    if style is not None:
        audio["speed_ratio"] = round(_clampf(style.speed_ratio, 0.2, 3.0), 2)
        audio["pitch_ratio"] = round(_clampf(style.pitch_ratio, 0.1, 3.0), 2)
        audio["volume_ratio"] = round(_clampf(style.volume_ratio, 0.1, 3.0), 2)
        if style.language and style.language.strip():
            audio["language"] = style.language.strip()
        if style.emotion and style.emotion.strip():
            audio["emotion"] = style.emotion.strip()

    req: dict[str, Any] = {
        "app": {
            "appid": appid,
            "token": token,
            "cluster": "volcano_tts",
        },
        "user": {"uid": "podcast-assistant"},
        "audio": audio,
        "request": {
            "reqid": reqid,
            "text": text,
            "text_type": "plain",
            "operation": "submit",
        },
    }
    raw = json.dumps(req, ensure_ascii=False).encode("utf-8")
    gz = gzip.compress(raw)
    return CLIENT_HEADER + struct.pack(">I", len(gz)) + gz


def _parse_server_frame(buf: bytes) -> dict[str, Any]:
    if len(buf) < 4:
        return {"kind": "unknown", "raw": buf}
    header_size = buf[0] & 0x0F
    message_type = buf[1] >> 4
    message_specific_flags = buf[1] & 0x0F
    message_compression = buf[2] & 0x0F
    offset = header_size * 4
    if offset > len(buf):
        return {"kind": "unknown", "raw": buf}
    payload = buf[offset:]
    if message_type == 0xB:
        if message_specific_flags == 0:
            return {"kind": "audio_start"}
        last = message_specific_flags == 3
        return {
            "kind": "audio",
            "data": payload[8:],
            "last": last,
        }
    if message_type == 0xF:
        err = payload[8:]
        if message_compression == 1 and err:
            try:
                err = gzip.decompress(err)
            except OSError:
                pass
        msg = err.decode("utf-8", errors="replace")
        return {"kind": "error", "message": msg}
    return {"kind": "other", "message_type": message_type}


def format_tts_error(api_message: str) -> str:
    """Parse JSON error body and add actionable hints (Chinese)."""
    try:
        data: Any = json.loads(api_message)
    except json.JSONDecodeError:
        return api_message
    if not isinstance(data, dict):
        return api_message
    code = data.get("code")
    backend = data.get("backend_code")
    msg = str(data.get("message", ""))
    reqid = data.get("reqid", "")
    lines = [
        f"火山 TTS 返回错误（HTTP/API code={code}, backend_code={backend}）",
        f"服务端说明: {msg}",
    ]
    if reqid:
        lines.append(f"reqid（联系客服/工单时请附上）: {reqid}")
    grant_issue = "grant" in msg.lower() and "not found" in msg.lower()
    if code == 401 or grant_issue:
        lines.extend(
            [
                "",
                "【排查】该错误一般表示 AppID 与 Token 在「豆包语音」侧对不上或未生效：",
                "· App ID、Access Token 必须来自火山「豆包语音」控制台里创建的应用详情页；",
                "· 不要使用：访问控制 IAM 的 AccessKey/SecretKey，或其它产品（如通用 OpenAPI）的密钥混用；",
                "· 确认已开通语音合成能力/有可用额度，复制 Token 时勿含空格或只复制了一半；",
                "· 官方说明见：豆包语音 API 接入 FAQ（关键词：load grant / appid 或 token 设置错误）。",
            ]
        )
    msg_l = msg.lower()
    quota_hit = (
        code == 429
        or backend == 45000292
        or "quota exceeded" in msg_l
        or "text_words" in msg_l
        or "lifetime" in msg_l
    )
    if quota_hit:
        lines.extend(
            [
                "",
                "【额度用尽】豆包语音侧判定：合成用字额度已超限（常见为试用/赠送字数用完）。",
                "· 登录火山引擎控制台 → 豆包语音 → 计费/资源包，查看用量并购买正式资源包或开通后付费；",
                "· 长稿会拆成多次请求，用量按「每次请求的文本」累计，可先缩短文案或调低「单次合成最大字数」减少失败重试带来的消耗；",
                "· 官方 FAQ 中「quota exceeded / 试用版用量」条目：https://www.volcengine.com/docs/6561/111522",
            ]
        )
    return "\n".join(lines)


def synthesize_mp3(
    appid: str,
    token: str,
    text: str,
    voice_type: str,
    *,
    style: TtsSpeechStyle | None = None,
) -> bytes:
    """One TTS request; text must already respect provider length limits."""
    stripped = text.strip()
    if not stripped:
        return b""
    reqid = str(uuid.uuid4())
    frame = _build_payload(
        appid, token, stripped, voice_type, reqid, style=style
    )

    ws = websocket.WebSocket(sslopt={"cert_reqs": ssl.CERT_NONE})
    auth = f"Bearer; {token}"
    ws.connect(WS_URL, header=[f"Authorization: {auth}"])
    try:
        ws.settimeout(120)
        ws.send(frame, opcode=websocket.ABNF.OPCODE_BINARY)
        out = bytearray()
        while True:
            try:
                msg = ws.recv()
            except websocket.WebSocketConnectionClosedException:
                break
            except websocket.WebSocketTimeoutException as e:
                raise RuntimeError("TTS 超时，请检查网络或文本长度") from e
            if not isinstance(msg, bytes):
                continue
            parsed = _parse_server_frame(msg)
            kind = parsed.get("kind")
            if kind == "audio":
                out.extend(parsed["data"])
                if parsed.get("last"):
                    break
            elif kind == "error":
                raw = parsed.get("message", "TTS error")
                raise RuntimeError(format_tts_error(raw))
            elif kind == "audio_start":
                continue
        if not out:
            raise RuntimeError("未收到音频数据，请检查 appId、密钥与音色 ID")
        return bytes(out)
    finally:
        try:
            ws.close()
        except Exception:
            pass
