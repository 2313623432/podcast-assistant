function Get-LogPath {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [Parameter(Mandatory=$true)][string]$Name
  )
  $logDir = Join-Path $Config.outputDir 'logs'
  return (Join-Path $logDir $Name)
}

function Write-RunLog {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [Parameter(Mandatory=$true)][string]$Message,
    $Data = $null
  )
  $path = Get-LogPath -Config $Config -Name 'run.log'
  $obj = [ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    message = $Message
    data = $Data
  }
  ($obj | ConvertTo-Json -Depth 20 -Compress) + "`n" | Add-Content -LiteralPath $path -Encoding UTF8
}

function Write-ErrorLog {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [Parameter(Mandatory=$true)][string]$Kind,
    [Parameter(Mandatory=$true)][string]$Message,
    $Data = $null
  )
  $path = Get-LogPath -Config $Config -Name 'error.log'
  $obj = [ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    kind = $Kind
    message = $Message
    data = $Data
  }
  ($obj | ConvertTo-Json -Depth 20 -Compress) + "`n" | Add-Content -LiteralPath $path -Encoding UTF8
}

