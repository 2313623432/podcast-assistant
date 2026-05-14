# -*- mode: python ; coding: utf-8 -*-

from PyInstaller.utils.hooks import collect_all

datas = [
    ("app.py", "."),
    ("podcast_core.py", "."),
    ("volcano_tts.py", "."),
    (".streamlit\\config.toml", ".streamlit"),
    (".env.example", "."),
    ("vendor\\ffmpeg\\bin\\ffmpeg.exe", "vendor\\ffmpeg\\bin"),
    ("vendor\\ffmpeg\\bin\\ffprobe.exe", "vendor\\ffmpeg\\bin"),
]
binaries = []
hiddenimports = []

for package in ("streamlit", "altair", "pyarrow", "pandas", "pydub", "dotenv", "websocket"):
    package_datas, package_binaries, package_hiddenimports = collect_all(package)
    datas += package_datas
    binaries += package_binaries
    hiddenimports += package_hiddenimports


a = Analysis(
    ["launcher.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="播客助手",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name="播客助手",
)
