function Split-TextIntoSentenceUnits {
  param(
    [Parameter(Mandatory=$true)][string]$Text
  )

  $t = $Text -replace "`r`n", "`n"
  $pPeriod = [char]0x3002
  $pExcl = [char]0xFF01
  $pQ = [char]0xFF1F
  $pSemi = [char]0xFF1B
  $units = New-Object System.Collections.Generic.List[string]
  $sb = New-Object System.Text.StringBuilder

  foreach ($ch in $t.ToCharArray()) {
    [void]$sb.Append($ch)
    if ($ch -eq "`n" -or $ch -eq $pPeriod -or $ch -eq $pExcl -or $ch -eq $pQ -or $ch -eq $pSemi) {
      $s = $sb.ToString()
      $sb.Clear() | Out-Null
      if ($s.Trim().Length -gt 0) { $units.Add($s) }
    }
  }

  $tail = $sb.ToString()
  if ($tail.Trim().Length -gt 0) { $units.Add($tail) }

  return $units.ToArray()
}

function Split-ToMaxChars {
  param(
    [Parameter(Mandatory=$true)][string]$Text,
    [Parameter(Mandatory=$true)][int]$MaxChars
  )

  $t = $Text
  $chunks = New-Object System.Collections.Generic.List[string]
  $comma = [char]0xFF0C
  $comma2 = [char]0x3001
  $colonFw = [char]0xFF1A
  $chars = @($comma, $comma2, $colonFw, ',', ':')
  $esc = ($chars | ForEach-Object { [regex]::Escape([string]$_) }) -join ''
  $pat = "[$esc\s](?=[^$esc\s]*$)"

  while ($t.Length -gt $MaxChars) {
    $cut = $MaxChars
    $m = [regex]::Match($t.Substring(0, $MaxChars), $pat)
    if ($m.Success) { $cut = $m.Index + 1 }
    $chunks.Add($t.Substring(0, $cut))
    $t = $t.Substring($cut)
  }
  if ($t.Length -gt 0) { $chunks.Add($t) }
  return $chunks.ToArray()
}

function Build-SpeechSegmentsSingle {
  param(
    [Parameter(Mandatory=$true)][string]$Text,
    [Parameter(Mandatory=$true)][string]$VoiceId,
    [Parameter(Mandatory=$true)][string]$SpeakerLabel,
    [Parameter(Mandatory=$true)][int]$MaxLineChars
  )

  $units = Split-TextIntoSentenceUnits -Text $Text
  $segments = New-Object System.Collections.Generic.List[object]

  foreach ($u in $units) {
    $chunks = Split-ToMaxChars -Text $u -MaxChars $MaxLineChars
    foreach ($c in $chunks) {
      $segments.Add([pscustomobject]@{
        kind = 'speech'
        speaker = $SpeakerLabel
        voiceId = $VoiceId
        text = $c
      })
    }
  }

  return $segments.ToArray()
}

function Build-SpeechSegmentsDual {
  param(
    [Parameter(Mandatory=$true)][string]$Text,
    [Parameter(Mandatory=$true)][string]$XiaoFangVoiceId,
    [Parameter(Mandatory=$true)][string]$DaLiuVoiceId,
    [Parameter(Mandatory=$true)][int]$MaxLineChars,
    [Parameter(Mandatory=$true)][string]$PauseSeed,
    [Parameter(Mandatory=$true)][double]$PauseMinSeconds,
    [Parameter(Mandatory=$true)][double]$PauseMaxSeconds
  )

  $units = Split-TextIntoSentenceUnits -Text $Text
  $segments = New-Object System.Collections.Generic.List[object]
  $z = Get-ZhStrings
  $turn = 0
  $pauseIndex = 0

  foreach ($u in $units) {
    $isXf = (($turn % 2) -eq 0)
    $speaker = $(if ($isXf) { $z.XiaoFang } else { $z.DaLiu })
    $voiceId = $(if ($isXf) { $XiaoFangVoiceId } else { $DaLiuVoiceId })

    $chunks = Split-ToMaxChars -Text $u -MaxChars $MaxLineChars
    foreach ($c in $chunks) {
      $segments.Add([pscustomobject]@{
        kind = 'speech'
        speaker = $speaker
        voiceId = $voiceId
        text = $c
      })
    }

    $turn++
    if ($turn -lt $units.Count) {
      $pause = Get-DeterministicPauseSeconds -Seed $PauseSeed -Index $pauseIndex -MinSeconds $PauseMinSeconds -MaxSeconds $PauseMaxSeconds
      $pauseIndex++
      $segments.Add([pscustomobject]@{
        kind = 'pause'
        seconds = $pause
      })
    }
  }

  return $segments.ToArray()
}

