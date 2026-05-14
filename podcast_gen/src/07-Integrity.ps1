function Test-SrtFile {
  param(
    [Parameter(Mandatory=$true)][string]$Path
  )
  $txt = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $blocks = $txt -split "(\r?\n){2,}"
  $ok = $false
  foreach ($b in $blocks) {
    $t = $b.Trim()
    if ($t.Length -eq 0) { continue }
    $lines = $t -split "\r?\n"
    if ($lines.Count -lt 3) { return $false }
    if (-not ($lines[0] -match '^\d+$')) { return $false }
    if (-not ($lines[1] -match '^\d{2}:\d{2}:\d{2},\d{3}\s-->\s\d{2}:\d{2}:\d{2},\d{3}$')) { return $false }
    $ok = $true
  }
  return $ok
}

function Test-OutputIntegrity {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [Parameter(Mandatory=$true)][string]$ManifestPath
  )

  if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "manifest_not_found: $ManifestPath"
  }

  $items = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($null -eq $items) { return }
  if ($items -isnot [System.Collections.IEnumerable]) { $items = @($items) }

  $z = Get-ZhStrings
  foreach ($it in $items) {
    $mp3Name = $it.($z.KeyAudioFile)
    if ($null -eq $mp3Name) { $mp3Name = $it.audioFile }
    $srtName = $it.($z.KeySrtFile)
    if ($null -eq $srtName) { $srtName = $it.srtFile }

    $mp3 = Join-Path $Config.outputDir ([string]$mp3Name)
    $srt = Join-Path $Config.outputDir ([string]$srtName)
    if (-not (Test-Path -LiteralPath $mp3)) { throw "audio_missing: $mp3" }
    if (-not (Test-Path -LiteralPath $srt)) { throw "srt_missing: $srt" }
    if ((Get-Item -LiteralPath $mp3).Length -le 0) { throw "audio_empty: $mp3" }
    if (-not (Test-SrtFile -Path $srt)) { throw "srt_parse_failed: $srt" }

    $durActual = Get-AudioDurationSeconds -Config $Config -Path $mp3
    $durManifestVal = $it.($z.KeyDuration)
    if ($null -eq $durManifestVal) { $durManifestVal = $it.durationSeconds }
    $durManifest = [double]$durManifestVal
    if ([Math]::Abs($durActual - $durManifest) -gt 0.2) {
      throw "duration_mismatch: $mp3Name manifest=$durManifest actual=$durActual"
    }
  }
}

