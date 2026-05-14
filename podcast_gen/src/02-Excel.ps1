function Read-ExcelTable {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [int]$SheetIndex = 1
  )

  $xl = $null
  $wb = $null
  $ws = $null
  $used = $null

  try {
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false
    $xl.DisplayAlerts = $false

    $wb = $xl.Workbooks.Open($Path)
    $ws = $wb.Worksheets.Item($SheetIndex)
    $used = $ws.UsedRange

    $rowCount = $used.Rows.Count
    $colCount = $used.Columns.Count
    if ($rowCount -lt 1 -or $colCount -lt 1) { return @() }

    $headers = @()
    for ($c = 1; $c -le $colCount; $c++) {
      $h = [string]$ws.Cells.Item(1, $c).Text
      $headers += $h.Trim()
    }

    $rows = @()
    for ($r = 2; $r -le $rowCount; $r++) {
      $o = [ordered]@{}
      for ($c = 1; $c -le $colCount; $c++) {
        $key = $headers[$c-1]
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $v = [string]$ws.Cells.Item($r, $c).Text
        if ($null -eq $v) { $v = '' }
        $o[$key] = $v
      }
      $rows += [pscustomobject]$o
    }

    return $rows
  } finally {
    try { if ($null -ne $wb) { $wb.Close($false) | Out-Null } } catch {}
    try { if ($null -ne $xl) { $xl.Quit() | Out-Null } } catch {}

    foreach ($obj in @($used,$ws,$wb,$xl)) {
      if ($null -ne $obj) {
        try { [Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null } catch {}
      }
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
  }
}

function Read-VoiceMap {
  param(
    [Parameter(Mandatory=$true)][string]$Path
  )

  $rows = Read-ExcelTable -Path $Path
  $z = Get-ZhStrings
  $colon = [char]0x003A
  $colonFw = [char]0xFF1A
  $map = [ordered]@{
    singles = @{}
    duo = @{
      xiaofang = $null
      daliu = $null
      label = $z.DuoLabel
    }
  }

  foreach ($r in $rows) {
    $props = @($r.PSObject.Properties)
    $name = [string]$props[0].Value
    $voice = [string]$props[1].Value
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($voice)) { continue }

    $xfPat = [regex]::Escape($z.XiaoFang) + "[$colon$colonFw]\s*([^\s]+)"
    $dlPat = [regex]::Escape($z.DaLiu) + "[$colon$colonFw]\s*([^\s]+)"
    $m1 = [regex]::Match($voice, $xfPat)
    $m2 = [regex]::Match($voice, $dlPat)
    if ($m1.Success -and $m2.Success) {
      $map.duo.xiaofang = $m1.Groups[1].Value
      $map.duo.daliu = $m2.Groups[1].Value
      $map.duo.label = $name.Trim()
      continue
    }

    $map.singles[$name] = $voice.Trim()
  }

  if ([string]::IsNullOrWhiteSpace($map.duo.xiaofang) -or [string]::IsNullOrWhiteSpace($map.duo.daliu)) {
    throw "duo voice ids not found in $Path"
  }

  return $map
}

function Read-ChapterRows {
  param(
    [Parameter(Mandatory=$true)][string]$InputDir,
    [Parameter(Mandatory=$true)][string]$VoiceXlsxPath
  )

  $files = Get-ChildItem -Path $InputDir -Filter '*.xlsx' -File | Where-Object { $_.FullName -ne $VoiceXlsxPath }

  $out = @()
  foreach ($f in $files) {
    $book = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $rows = Read-ExcelTable -Path $f.FullName
    $idx = 0
    foreach ($r in $rows) {
      $idx++
      $props = @($r.PSObject.Properties)
      $chapterName = [string]$props[0].Value
      $chapterContent = [string]$props[1].Value
      $speaker = [string]$props[2].Value

      $item = [ordered]@{
        book = $book
        rowIndex = $idx
        chapterName = $chapterName
        chapterContent = $chapterContent
        speaker = $speaker
        sourceFile = $f.FullName
      }

      $out += [pscustomobject]$item
    }
  }

  return $out
}

