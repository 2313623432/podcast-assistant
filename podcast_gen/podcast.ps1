param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
  [string[]]$OnlyFiles = @(),
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$srcDir = Join-Path $PSScriptRoot 'src'
Get-ChildItem -Path $srcDir -Filter '*.ps1' -File | Sort-Object FullName | ForEach-Object { . $_.FullName }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
  $fallback = Join-Path $PSScriptRoot 'config.example.json'
  if (Test-Path -LiteralPath $fallback) {
    $ConfigPath = $fallback
  } else {
    $ConfigPath = ''
  }
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $config = [pscustomobject]@{
    voiceXlsx = 'D:\播客\声音id和api.xlsx'
    inputDir = 'D:\播客'
    outputDir = 'D:\播客\podcast_output'
    tempDir = 'D:\播客\podcast_temp'
    tts = [pscustomobject]@{
      mode = 'openspeech_v1'
      baseUrl = 'https://openspeech.bytedance.com/api/v1/tts'
      authHeader = 'Authorization'
      authScheme = 'Bearer'
      apiKeyEnv = 'BYTEDANCE_TTS_KEY'
      appId = ''
      userId = 'podcast-gen'
      audio = [pscustomobject]@{ encoding = 'mp3'; sample_rate = 24000 }
      request = [pscustomobject]@{ text_type = 'plain'; operation = 'query' }
    }
    audio = [pscustomobject]@{
      ffmpegPath = 'ffmpeg'
      ffprobePath = 'ffprobe'
      targetSampleRate = 44100
      targetChannels = 2
      targetBitrateK = 192
      lufsI = -16
      pauseSecondsMin = 0.3
      pauseSecondsMax = 0.8
    }
    srt = [pscustomobject]@{ maxLineChars = 20 }
    generation = [pscustomobject]@{ modes = @('single','dual') }
  }
} else {
  $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

Initialize-Directories -Config $config

$voiceMap = Read-VoiceMap -Path $config.voiceXlsx
$chapters = Read-ChapterRows -InputDir $config.inputDir -VoiceXlsxPath $config.voiceXlsx
if ($OnlyFiles.Count -gt 0) {
  $targets = @($OnlyFiles | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
  $chapters = @($chapters | Where-Object { $targets -contains $_.sourceFile })
}

$modes = @()
if ($null -ne $config.generation -and $null -ne $config.generation.modes) {
  $modes = @($config.generation.modes)
}
if ($modes.Count -eq 0) {
  $modes = @('single','dual')
}

$manifestItems = @()
$runTs = (Get-Date).ToUniversalTime().ToString('o')

foreach ($chapter in $chapters) {
  foreach ($mode in $modes) {
    try {
      $item = Invoke-GeneratePodcastItem -Config $config -VoiceMap $voiceMap -Chapter $chapter -Mode $mode -RunTimestamp $runTs -DryRun:$DryRun
      if ($null -ne $item) {
        $manifestItems += $item
      }
    } catch {
      Write-ErrorLog -Config $config -Kind 'generation_failed' -Message $_.Exception.Message -Data $chapter
    }
  }
}

$manifestPath = Join-Path $config.outputDir 'manifest.json'
$manifestJson = ($manifestItems | ConvertTo-Json -Depth 20)
if ([string]::IsNullOrWhiteSpace($manifestJson)) { $manifestJson = '[]' }
$manifestJson | Set-Content -LiteralPath $manifestPath -Encoding UTF8

if (-not $DryRun) {
  Test-OutputIntegrity -Config $config -ManifestPath $manifestPath
}
