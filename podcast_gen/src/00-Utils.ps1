function Initialize-Directories {
  param(
    [Parameter(Mandatory=$true)]$Config
  )

  foreach ($p in @($Config.outputDir, $Config.tempDir)) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if (-not (Test-Path -LiteralPath $p)) {
      New-Item -ItemType Directory -Path $p | Out-Null
    }
  }

  $logDir = Join-Path $Config.outputDir 'logs'
  if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
  }
}

function New-UString {
  param(
    [Parameter(Mandatory=$true)][int[]]$CodePoints
  )
  $chars = foreach ($cp in $CodePoints) { [char]$cp }
  return (-join $chars)
}

function Get-ZhStrings {
  if ($script:ZhStrings) { return $script:ZhStrings }

  $xiaofang = New-UString -CodePoints @(0x5C0F,0x82B3)
  $daliu = New-UString -CodePoints @(0x5927,0x5218)
  $duoLabel = $xiaofang + $daliu + '-' + (New-UString -CodePoints @(0x53CC,0x4EBA,0x5E7D,0x9ED8,0x7248))

  $k1 = New-UString -CodePoints @(0x97F3,0x9891,0x6587,0x4EF6,0x540D)
  $k2 = 'srt' + (New-UString -CodePoints @(0x6587,0x4EF6,0x540D))
  $k3 = New-UString -CodePoints @(0x65F6,0x957F)
  $k4 = New-UString -CodePoints @(0x751F,0x6210,0x65F6,0x95F4,0x6233)
  $k5 = New-UString -CodePoints @(0x89D2,0x8272,0x5206,0x914D)
  $k6 = New-UString -CodePoints @(0x539F,0x59CB,0x5185,0x5BB9,0x6458,0x8981)
  $k7 = New-UString -CodePoints @(0x6A21,0x5F0F)
  $k8 = New-UString -CodePoints @(0x540D,0x79F0)
  $k9 = New-UString -CodePoints @(0x5BF9,0x5E94,0x4EBA,0x7269)
  $k10 = New-UString -CodePoints @(0x5BF9,0x5E94,0x4E66)
  $k11 = New-UString -CodePoints @(0x5BF9,0x5E94,0x7AE0,0x8282)
  $k12 = New-UString -CodePoints @(0x6E90,0x6587,0x4EF6)
  $k13 = New-UString -CodePoints @(0x6E90,0x884C)

  $script:ZhStrings = [ordered]@{
    XiaoFang = $xiaofang
    DaLiu = $daliu
    DuoLabel = $duoLabel
    KeyAudioFile = $k1
    KeySrtFile = $k2
    KeyDuration = $k3
    KeyGeneratedAt = $k4
    KeyRoleAssignment = $k5
    KeySourceSummary = $k6
    KeyMode = $k7
    KeyName = $k8
    KeyPerson = $k9
    KeyBook = $k10
    KeyChapter = $k11
    KeySourceFile = $k12
    KeySourceRow = $k13
  }

  return $script:ZhStrings
}

function New-Guid {
  [Guid]::NewGuid().ToString()
}

function Sanitize-FileNamePart {
  param(
    [Parameter(Mandatory=$true)][string]$Value
  )
  $v = $Value.Trim()
  $invalid = [IO.Path]::GetInvalidFileNameChars()
  foreach ($c in $invalid) {
    $v = $v.Replace([string]$c, ' ')
  }
  $v = ($v -replace '\s+', ' ').Trim()
  if ($v.Length -gt 80) { $v = $v.Substring(0, 80).Trim() }
  if ($v.Length -eq 0) { return 'unnamed' }
  return $v
}

function Get-ChapterCode {
  param(
    [Parameter(Mandatory=$true)][string]$ChapterName,
    [Parameter(Mandatory=$true)][int]$RowIndex
  )

  $di = [char]0x7B2C
  $zhang = [char]0x7AE0
  if ($ChapterName.Length -ge 2 -and $ChapterName[0] -eq $di) {
    $pos = $ChapterName.IndexOf($zhang)
    if ($pos -gt 0 -and $pos -le 12) {
      return $ChapterName.Substring(0, $pos + 1)
    }
  }
  return ([string]$di + $RowIndex.ToString('00') + [string]$zhang)
}

function Get-DeterministicUnitFloat {
  param(
    [Parameter(Mandatory=$true)][string]$Seed,
    [Parameter(Mandatory=$true)][int]$Index
  )
  $bytes = [Text.Encoding]::UTF8.GetBytes("$Seed|$Index")
  $sha = [Security.Cryptography.SHA256]::Create()
  $hash = $sha.ComputeHash($bytes)
  $sha.Dispose()
  $u = [BitConverter]::ToUInt32($hash, 0)
  return ($u / [uint32]::MaxValue)
}

function Get-DeterministicPauseSeconds {
  param(
    [Parameter(Mandatory=$true)][string]$Seed,
    [Parameter(Mandatory=$true)][int]$Index,
    [Parameter(Mandatory=$true)][double]$MinSeconds,
    [Parameter(Mandatory=$true)][double]$MaxSeconds
  )
  $u = Get-DeterministicUnitFloat -Seed $Seed -Index $Index
  return [Math]::Round(($MinSeconds + ($MaxSeconds - $MinSeconds) * $u), 3)
}

function Format-SrtTime {
  param(
    [Parameter(Mandatory=$true)][double]$Seconds
  )
  if ($Seconds -lt 0) { $Seconds = 0 }
  $totalMs = [Math]::Round($Seconds * 1000)
  $ms = $totalMs % 1000
  $totalSec = [Math]::Floor($totalMs / 1000)
  $sec = $totalSec % 60
  $totalMin = [Math]::Floor($totalSec / 60)
  $min = $totalMin % 60
  $hour = [Math]::Floor($totalMin / 60)
  return ('{0:00}:{1:00}:{2:00},{3:000}' -f $hour, $min, $sec, $ms)
}

function Get-EnvOrThrow {
  param(
    [Parameter(Mandatory=$true)][string]$Name
  )
  $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
  if ([string]::IsNullOrWhiteSpace($v)) {
    $v = [Environment]::GetEnvironmentVariable($Name, 'User')
  }
  if ([string]::IsNullOrWhiteSpace($v)) {
    $v = [Environment]::GetEnvironmentVariable($Name, 'Machine')
  }
  if ([string]::IsNullOrWhiteSpace($v)) {
    throw "env_missing: $Name"
  }
  return $v
}

function ConvertFrom-SecureStringPlain {
  param(
    [Parameter(Mandatory=$true)][securestring]$Secure
  )
  $bstr = [IntPtr]::Zero
  try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    if ($bstr -ne [IntPtr]::Zero) {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  }
}

function Get-EnvOrPromptSecret {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [string]$Prompt = ''
  )
  $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
  if ([string]::IsNullOrWhiteSpace($v)) {
    $v = [Environment]::GetEnvironmentVariable($Name, 'User')
  }
  if ([string]::IsNullOrWhiteSpace($v)) {
    $v = [Environment]::GetEnvironmentVariable($Name, 'Machine')
  }
  if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }

  if ([string]::IsNullOrWhiteSpace($Prompt)) { $Prompt = "Enter $Name" }
  $sec = Read-Host -Prompt $Prompt -AsSecureString
  $plain = ConvertFrom-SecureStringPlain -Secure $sec
  if ([string]::IsNullOrWhiteSpace($plain)) { throw "env_missing: $Name" }
  return $plain
}

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory=$true)][scriptblock]$Action,
    [int]$MaxAttempts = 3,
    [int]$BaseDelayMs = 500
  )

  $attempt = 0
  while ($true) {
    $attempt++
    try {
      return & $Action
    } catch {
      if ($attempt -ge $MaxAttempts) { throw }
      $delay = $BaseDelayMs * [Math]::Pow(2, $attempt - 1)
      Start-Sleep -Milliseconds ([int]$delay)
    }
  }
}

