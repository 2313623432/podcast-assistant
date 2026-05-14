function Invoke-BytedanceTtsToFile {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [Parameter(Mandatory=$true)][string]$VoiceId,
    [Parameter(Mandatory=$true)][string]$Text,
    [Parameter(Mandatory=$true)][string]$OutPath
  )

  $mode = [string]$Config.tts.mode
  if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'openspeech_v1' }
  if ($mode -ne 'openspeech_v1') {
    throw "unsupported tts.mode: $mode"
  }

  $envName = [string]$Config.tts.apiKeyEnv
  if ([string]::IsNullOrWhiteSpace($envName)) { $envName = 'BYTEDANCE_TTS_KEY' }
  $apiKey = Get-EnvOrPromptSecret -Name $envName -Prompt "Enter API key for $envName"
  $headerName = [string]$Config.tts.authHeader
  if ([string]::IsNullOrWhiteSpace($headerName)) { $headerName = 'Authorization' }
  $scheme = [string]$Config.tts.authScheme
  $headerValue = $(if ([string]::IsNullOrWhiteSpace($scheme)) { $apiKey } else { "$scheme $apiKey" })

  $headers = @{}
  $headers[$headerName] = $headerValue

  $audioObj = @{}
  if ($null -ne $Config.tts.audio) {
    foreach ($p in $Config.tts.audio.PSObject.Properties) {
      $audioObj[$p.Name] = $p.Value
    }
  }
  $audioObj['voice_type'] = $VoiceId

  $reqObj = @{}
  if ($null -ne $Config.tts.request) {
    foreach ($p in $Config.tts.request.PSObject.Properties) {
      $reqObj[$p.Name] = $p.Value
    }
  }
  $reqObj['text'] = $Text
  $reqObj['reqid'] = New-Guid

  $bodyObj = [ordered]@{
    app = [ordered]@{ appid = [string]$Config.tts.appId }
    user = [ordered]@{ uid = [string]$Config.tts.userId }
    audio = $audioObj
    request = $reqObj
  }

  $body = $bodyObj | ConvertTo-Json -Depth 20 -Compress
  $url = [string]$Config.tts.baseUrl
  if ([string]::IsNullOrWhiteSpace($url)) { throw 'missing tts.baseUrl' }

  $action = {
    $resp = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 120 -UseBasicParsing
    $ct = [string]$resp.Headers['Content-Type']
    if ($ct -like 'application/json*' -or $resp.Content.TrimStart().StartsWith('{')) {
      $json = $resp.Content | ConvertFrom-Json
      $code = $json.code
      if ($null -ne $code -and [int]$code -ne 0) {
        $msg = [string]$json.message
        throw "tts_error code=$code message=$msg"
      }
      $b64 = $json.data.audio
      if ([string]::IsNullOrWhiteSpace($b64)) { throw 'tts_response_missing_data_audio' }
      [IO.File]::WriteAllBytes($OutPath, [Convert]::FromBase64String($b64))
      return $OutPath
    }

    $ms = New-Object IO.MemoryStream
    $resp.RawContentStream.CopyTo($ms)
    [IO.File]::WriteAllBytes($OutPath, $ms.ToArray())
    $ms.Dispose()
    return $OutPath
  }

  return Invoke-WithRetry -Action $action -MaxAttempts 3 -BaseDelayMs 800
}

