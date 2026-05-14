$ErrorActionPreference = "Stop"

Set-Location -LiteralPath $PSScriptRoot

python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python -m pip install pyinstaller

$ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
$ffprobe = (Get-Command ffprobe -ErrorAction SilentlyContinue).Source
if (-not $ffmpeg -or -not $ffprobe) {
    throw "找不到 ffmpeg/ffprobe。请先安装或把它们放到 PATH 后再运行。"
}

$vendorBin = Join-Path $PSScriptRoot "vendor\ffmpeg\bin"
New-Item -ItemType Directory -Force -Path $vendorBin | Out-Null
Copy-Item -LiteralPath $ffmpeg -Destination (Join-Path $vendorBin "ffmpeg.exe") -Force
Copy-Item -LiteralPath $ffprobe -Destination (Join-Path $vendorBin "ffprobe.exe") -Force

pyinstaller --noconfirm --clean ".\播客助手.spec"

Write-Host ""
Write-Host "打包完成：$PSScriptRoot\dist\播客助手\播客助手.exe"
Write-Host "如需单文件版，运行：pyinstaller --noconfirm --clean '.\播客助手-单文件.spec'"
