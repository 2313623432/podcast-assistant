function Invoke-External {
  param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [Parameter(Mandatory=$true)][string[]]$Args
  )
  $p = Start-Process -FilePath $Exe -ArgumentList $Args -NoNewWindow -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    throw "external_command_failed: $Exe (exit=$($p.ExitCode))"
  }
}

function Assert-AudioTools {
  param(
    [Parameter(Mandatory=$true)]$Config
  )
  $ffmpeg = [string]$Config.audio.ffmpegPath
  $ffprobe = [string]$Config.audio.ffprobePath
  if ([string]::IsNullOrWhiteSpace($ffmpeg)) { $ffmpeg = 'ffmpeg' }
  if ([string]::IsNullOrWhiteSpace($ffprobe)) { $ffprobe = 'ffprobe' }
  try {
    Invoke-External -Exe $ffmpeg -Args @('-version') | Out-Null
  } catch {
    throw "ffmpeg_not_found: $ffmpeg"
  }
  try {
    Invoke-External -Exe $ffprobe -Args @('-version') | Out-Null
  } catch {
    throw "ffprobe_not_found: $ffprobe"
  }
}

function Get-AudioDurationSeconds {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [Parameter(Mandatory=$true)][string]$Path
  )

  $ffprobe = [string]$Config.audio.ffprobePath
  if ([string]::IsNullOrWhiteSpace($ffprobe)) { $ffprobe = 'ffprobe' }

  try {
    $args = @('-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1', $Path)
    $out = & $ffprobe @args 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($out)) {
      return [double]($out.Trim())
    }
  } catch {}

  $wmp = $null
  try {
    $wmp = New-Object -ComObject WMPlayer.OCX
    $media = $wmp.newMedia($Path)
    return [double]$media.duration
  } finally {
    if ($null -ne $wmp) {
      try { $wmp.close() | Out-Null } catch {}
      try { [Runtime.InteropServices.Marshal]::ReleaseComObject($wmp) | Out-Null } catch {}
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
    }
  }
}

function Convert-ToWav {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [Parameter(Mandatory=$true)][string]$InPath,
    [Parameter(Mandatory=$true)][string]$OutPath
  )
  $ffmpeg = [string]$Config.audio.ffmpegPath
  if ([string]::IsNullOrWhiteSpace($ffmpeg)) { $ffmpeg = 'ffmpeg' }
  $sr = [int]$Config.audio.targetSampleRate
  $ch = [int]$Config.audio.targetChannels
  Invoke-External -Exe $ffmpeg -Args @('-y','-i',$InPath,'-ar',"$sr",'-ac',"$ch",$OutPath)
  return $OutPath
}

function New-SilenceWav {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [Parameter(Mandatory=$true)][double]$Seconds,
    [Parameter(Mandatory=$true)][string]$OutPath
  )
  $ffmpeg = [string]$Config.audio.ffmpegPath
  if ([string]::IsNullOrWhiteSpace($ffmpeg)) { $ffmpeg = 'ffmpeg' }
  $sr = [int]$Config.audio.targetSampleRate
  Invoke-External -Exe $ffmpeg -Args @('-y','-f','lavfi','-i',"anullsrc=r=$sr:cl=stereo",'-t',"$Seconds",$OutPath)
  return $OutPath
}

function Write-ConcatListFile {
  param(
    [Parameter(Mandatory=$true)][string[]]$Paths,
    [Parameter(Mandatory=$true)][string]$ListPath
  )
  $lines = foreach ($p in $Paths) {
    $pp = $p.Replace("'", "''")
    "file '$pp'"
  }
  $lines -join "`n" | Set-Content -LiteralPath $ListPath -Encoding UTF8
}

function Concat-WavFiles {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [Parameter(Mandatory=$true)][string[]]$WavPaths,
    [Parameter(Mandatory=$true)][string]$OutPath
  )
  $ffmpeg = [string]$Config.audio.ffmpegPath
  if ([string]::IsNullOrWhiteSpace($ffmpeg)) { $ffmpeg = 'ffmpeg' }
  $listPath = Join-Path ([IO.Path]::GetDirectoryName($OutPath)) ('concat_' + (New-Guid) + '.txt')
  Write-ConcatListFile -Paths $WavPaths -ListPath $listPath
  Invoke-External -Exe $ffmpeg -Args @('-y','-f','concat','-safe','0','-i',$listPath,'-c','copy',$OutPath)
  Remove-Item -LiteralPath $listPath -Force -ErrorAction SilentlyContinue
  return $OutPath
}

function Normalize-ToMp3 {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [Parameter(Mandatory=$true)][string]$InWavPath,
    [Parameter(Mandatory=$true)][string]$OutMp3Path
  )
  $ffmpeg = [string]$Config.audio.ffmpegPath
  if ([string]::IsNullOrWhiteSpace($ffmpeg)) { $ffmpeg = 'ffmpeg' }
  $sr = [int]$Config.audio.targetSampleRate
  $ch = [int]$Config.audio.targetChannels
  $br = [int]$Config.audio.targetBitrateK
  $lufs = [double]$Config.audio.lufsI
  Invoke-External -Exe $ffmpeg -Args @('-y','-i',$InWavPath,'-af',"loudnorm=I=$lufs:TP=-1.5:LRA=11",'-ar',"$sr",'-ac',"$ch",'-b:a',"$br"+'k',$OutMp3Path)
  return $OutMp3Path
}

