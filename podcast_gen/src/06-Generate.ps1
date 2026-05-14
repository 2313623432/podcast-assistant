function Write-SrtFile {
  param(
    [Parameter(Mandatory=$true)][object[]]$Items,
    [Parameter(Mandatory=$true)][string]$OutPath
  )

  $sb = New-Object System.Text.StringBuilder
  foreach ($it in $Items) {
    [void]$sb.AppendLine([string]$it.index)
    [void]$sb.AppendLine(("{0} --> {1}" -f $it.start, $it.end))
    [void]$sb.AppendLine([string]$it.text)
    [void]$sb.AppendLine()
  }
  $sb.ToString() | Set-Content -LiteralPath $OutPath -Encoding UTF8
}

$script:AudioToolsChecked = $false

function Invoke-GeneratePodcastItem {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [Parameter(Mandatory=$true)]$VoiceMap,
    [Parameter(Mandatory=$true)]$Chapter,
    [Parameter(Mandatory=$true)][string]$Mode,
    [Parameter(Mandatory=$true)][string]$RunTimestamp,
    [switch]$DryRun
  )

  if (-not $DryRun) {
    if (-not $script:AudioToolsChecked) {
      Assert-AudioTools -Config $Config
      $script:AudioToolsChecked = $true
    }
  }

  $chapterName = [string]$Chapter.chapterName
  $chapterContent = [string]$Chapter.chapterContent
  $speakerName = [string]$Chapter.speaker
  $book = [string]$Chapter.book
  $z = Get-ZhStrings

  if ([string]::IsNullOrWhiteSpace($chapterName) -or [string]::IsNullOrWhiteSpace($chapterContent) -or [string]::IsNullOrWhiteSpace($speakerName)) {
    Write-ErrorLog -Config $Config -Kind 'missing_required_fields' -Message 'missing required fields, skipped' -Data $Chapter
    return $null
  }

  $modeNorm = $Mode.ToLowerInvariant()
  if ($modeNorm -ne 'single' -and $modeNorm -ne 'dual') {
    Write-ErrorLog -Config $Config -Kind 'invalid_mode' -Message "unsupported mode: $Mode" -Data $Chapter
    return $null
  }

  $jobId = New-Guid
  $workDir = Join-Path $Config.tempDir $jobId
  New-Item -ItemType Directory -Path $workDir | Out-Null

  $maxLineChars = [int]$Config.srt.maxLineChars
  if ($maxLineChars -le 0) { $maxLineChars = 20 }

  $pauseMin = [double]$Config.audio.pauseSecondsMin
  $pauseMax = [double]$Config.audio.pauseSecondsMax
  if ($pauseMin -le 0) { $pauseMin = 0.3 }
  if ($pauseMax -lt $pauseMin) { $pauseMax = $pauseMin }

  $segments = @()
  $personLabel = ''
  $roleAssignment = $null

  if ($modeNorm -eq 'single') {
    if (-not $VoiceMap.singles.ContainsKey($speakerName)) {
      Write-ErrorLog -Config $Config -Kind 'missing_voice_id' -Message "speaker voice id not found: $speakerName" -Data $Chapter
      return $null
    }
    $voiceId = [string]$VoiceMap.singles[$speakerName]
    $personLabel = $speakerName
    $roleAssignment = [ordered]@{ $speakerName = $voiceId }
    $segments = Build-SpeechSegmentsSingle -Text $chapterContent -VoiceId $voiceId -SpeakerLabel $speakerName -MaxLineChars $maxLineChars
  }

  if ($modeNorm -eq 'dual') {
    $personLabel = [string]$VoiceMap.duo.label
    $roleAssignment = [ordered]@{ $z.XiaoFang = [string]$VoiceMap.duo.xiaofang; $z.DaLiu = [string]$VoiceMap.duo.daliu }
    $segments = Build-SpeechSegmentsDual -Text $chapterContent -XiaoFangVoiceId $VoiceMap.duo.xiaofang -DaLiuVoiceId $VoiceMap.duo.daliu -MaxLineChars $maxLineChars -PauseSeed "$book|$($Chapter.rowIndex)|$personLabel" -PauseMinSeconds $pauseMin -PauseMaxSeconds $pauseMax
  }

  $safeName = Sanitize-FileNamePart -Value $chapterName
  $safePerson = Sanitize-FileNamePart -Value $personLabel
  $safeBook = Sanitize-FileNamePart -Value $book
  $chapterCode = Get-ChapterCode -ChapterName $chapterName -RowIndex ([int]$Chapter.rowIndex)
  $safeChapter = Sanitize-FileNamePart -Value $chapterCode

  $mp3FileName = '{0}_{1}_{2}_{3}.mp3' -f $safeName, $safePerson, $safeBook, $safeChapter
  $mp3Path = Join-Path $Config.outputDir $mp3FileName

  $summary = $chapterContent.Trim()
  if ($summary.Length -gt 120) { $summary = $summary.Substring(0, 120) }

  if ($DryRun) {
    $item = [ordered]@{
      $z.KeyAudioFile = $mp3FileName
      $z.KeySrtFile = ''
      $z.KeyDuration = $null
      $z.KeyGeneratedAt = $RunTimestamp
      $z.KeyRoleAssignment = $roleAssignment
      $z.KeySourceSummary = $summary
      $z.KeyMode = $modeNorm
      $z.KeyName = $chapterName
      $z.KeyPerson = $personLabel
      $z.KeyBook = $book
      $z.KeyChapter = $chapterCode
      $z.KeySourceFile = $Chapter.sourceFile
      $z.KeySourceRow = $Chapter.rowIndex
    }
    Write-RunLog -Config $Config -Message 'dry_run_planned' -Data $item
    return [pscustomobject]$item
  }

  $wavParts = New-Object System.Collections.Generic.List[string]
  $srtItems = New-Object System.Collections.Generic.List[object]
  $t = 0.0
  $speechIndex = 0
  $partIndex = 0

  foreach ($seg in $segments) {
    $partIndex++
    if ($seg.kind -eq 'speech') {
      $text = [string]$seg.text
      $voiceId = [string]$seg.voiceId

      $mp3Part = Join-Path $workDir ("part_{0:0000}.mp3" -f $partIndex)
      $wavPart = Join-Path $workDir ("part_{0:0000}.wav" -f $partIndex)

      try {
        Invoke-BytedanceTtsToFile -Config $Config -VoiceId $voiceId -Text $text -OutPath $mp3Part | Out-Null
      } catch {
        Write-ErrorLog -Config $Config -Kind 'tts_failed' -Message $_.Exception.Message -Data ([ordered]@{ chapter=$Chapter; segmentText=$text; voiceId=$voiceId; mode=$modeNorm })
        throw
      }

      Convert-ToWav -Config $Config -InPath $mp3Part -OutPath $wavPart | Out-Null
      $dur = Get-AudioDurationSeconds -Config $Config -Path $wavPart
      $wavParts.Add($wavPart)

      $speechIndex++
      $start = $t
      $end = $t + $dur
      $t = $end

      $capText = ($text -replace "`r`n"," " -replace "`n"," ").Trim()
      $srtItems.Add([pscustomobject]@{
        index = $speechIndex
        start = (Format-SrtTime -Seconds $start)
        end = (Format-SrtTime -Seconds $end)
        text = $capText
      })
      continue
    }

    if ($seg.kind -eq 'pause') {
      $secs = [double]$seg.seconds
      if ($secs -le 0) { continue }
      $wavPause = Join-Path $workDir ("pause_{0:0000}.wav" -f $partIndex)
      New-SilenceWav -Config $Config -Seconds $secs -OutPath $wavPause | Out-Null
      $wavParts.Add($wavPause)
      $t += $secs
      continue
    }
  }

  $combinedWav = Join-Path $workDir 'combined.wav'
  Concat-WavFiles -Config $Config -WavPaths @($wavParts) -OutPath $combinedWav | Out-Null

  Normalize-ToMp3 -Config $Config -InWavPath $combinedWav -OutMp3Path $mp3Path | Out-Null

  $durationSeconds = Get-AudioDurationSeconds -Config $Config -Path $mp3Path
  $durationRounded = [Math]::Round($durationSeconds, 1)

  $durPrefix = ($durationRounded.ToString('0.0') + 's')
  $srtFileName = '{0}_{1}_{2}_{3}_{4}.srt' -f $durPrefix, $safeName, $safePerson, $safeBook, $safeChapter
  $srtPath = Join-Path $Config.outputDir $srtFileName
  Write-SrtFile -Items @($srtItems) -OutPath $srtPath

  $item = [ordered]@{
    $z.KeyAudioFile = $mp3FileName
    $z.KeySrtFile = $srtFileName
    $z.KeyDuration = $durationRounded
    $z.KeyGeneratedAt = $RunTimestamp
    $z.KeyRoleAssignment = $roleAssignment
    $z.KeySourceSummary = $summary
    $z.KeyMode = $modeNorm
    $z.KeyName = $chapterName
    $z.KeyPerson = $personLabel
    $z.KeyBook = $book
    $z.KeyChapter = $chapterCode
    $z.KeySourceFile = $Chapter.sourceFile
    $z.KeySourceRow = $Chapter.rowIndex
  }

  Write-RunLog -Config $Config -Message 'generated' -Data $item
  return [pscustomobject]$item
}

