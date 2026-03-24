# Local backend (static file server) for this folder.
# Starts: http://127.0.0.1:3000/
#
# This server serves static files and provides a small JSON API for persistence.
# It is intentionally dependency-free (uses .NET HttpListener).

param(
  [int]$Port = 3000
)

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ErrorActionPreference = "Stop"

function Get-DefaultHtml {
  $candidates = @('yellow-circle.html', 'index.html.html', 'index.html')
  foreach ($name in $candidates) {
    $p = Join-Path $RootDir $name
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $name }
  }

  $all = Get-ChildItem -Path $RootDir -File -Filter *.html | Select-Object -First 1
  if ($null -ne $all) { return $all.Name }
  return $null
}

$defaultHtml = Get-DefaultHtml

$DataPath = Join-Path $RootDir 'yc_data.json'
$AdminPath = Join-Path $RootDir 'yc_admin.json'

function Get-ContentType([string]$filePath) {
  $ext = ([IO.Path]::GetExtension($filePath)).ToLowerInvariant()
  switch ($ext) {
    '.html' { 'text/html; charset=utf-8' }
    '.css'  { 'text/css; charset=utf-8' }
    '.js'   { 'text/javascript; charset=utf-8' }
    '.json' { 'application/json; charset=utf-8' }
    '.svg'  { 'image/svg+xml; charset=utf-8' }
    '.png'  { 'image/png' }
    '.jpg'   { 'image/jpeg' }
    '.jpeg'  { 'image/jpeg' }
    '.gif'  { 'image/gif' }
    '.webp' { 'image/webp' }
    '.txt'  { 'text/plain; charset=utf-8' }
    default  { 'application/octet-stream' }
  }
}

function Send-TextResponse($context, [int]$statusCode, [string]$body, [string]$contentType = 'text/plain; charset=utf-8') {
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  $context.Response.StatusCode = $statusCode
  $context.Response.ContentType = $contentType
  $context.Response.ContentLength64 = $bytes.Length
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $context.Response.OutputStream.Close()
}

function Serve-File($context, [string]$filePath) {
  if (!(Test-Path -LiteralPath $filePath -PathType Leaf)) { return $false }

  $bytes = [IO.File]::ReadAllBytes($filePath)
  $context.Response.StatusCode = 200
  $context.Response.ContentType = (Get-ContentType $filePath)
  $context.Response.ContentLength64 = $bytes.Length
  $context.Response.AddHeader('Cache-Control', 'no-store')
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $context.Response.OutputStream.Close()
  return $true
}

function Serve-DefaultHtml($context) {
  if ([string]::IsNullOrWhiteSpace($defaultHtml)) {
    Send-TextResponse $context 500 "No default HTML file found in this folder."
    return
  }
  $p = Join-Path $RootDir $defaultHtml
  [void](Serve-File $context $p)
}

function Safe-ResolvePath([string]$urlPath) {
  # urlPath starts with '/...'
  if ([string]::IsNullOrWhiteSpace($urlPath)) { return $null }

  $rel = $urlPath.TrimStart('/')
  if ([string]::IsNullOrWhiteSpace($rel)) { return $null }

  # Decode percent-encoding and block path traversal.
  try { $rel = [Uri]::UnescapeDataString($rel) } catch { }
  if ($rel -match '\.\.') { return $null }
  if ($rel -match ':') { return $null } # prevent drive letters / schemes
  if ($rel -match '\\') { return $null } # avoid Windows backslash tricks

  $candidate = Join-Path $RootDir $rel
  try {
    $resolvedRoot = [IO.Path]::GetFullPath($RootDir)
    $resolvedCandidate = [IO.Path]::GetFullPath($candidate)
    if (-not $resolvedCandidate.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $resolvedCandidate
  } catch {
    return null
  }
}

function Read-RequestBodyAsJson($context) {
  try {
    $encoding = $context.Request.ContentEncoding
    if ($null -eq $encoding) { $encoding = [Text.Encoding]::UTF8 }
    $reader = New-Object System.IO.StreamReader($context.Request.InputStream, $encoding)
    $raw = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
}

function Load-YCData {
  if (!(Test-Path -LiteralPath $DataPath -PathType Leaf)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $DataPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
}

function Save-YCData($obj) {
  try {
    $json = $obj | ConvertTo-Json -Depth 64 -ErrorAction Stop
    Set-Content -LiteralPath $DataPath -Value $json -Encoding UTF8
    return $true
  } catch {
    return $false
  }
}

function Load-Admin {
  if (!(Test-Path -LiteralPath $AdminPath -PathType Leaf)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $AdminPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
}

function Save-Admin($obj) {
  try {
    $json = $obj | ConvertTo-Json -Depth 20 -ErrorAction Stop
    Set-Content -LiteralPath $AdminPath -Value $json -Encoding UTF8
    return $true
  } catch {
    return $false
  }
}

$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)

Write-Host "Local server listening on $prefix"
Write-Host "Default route: http://127.0.0.1:$Port/"
Write-Host "Health: http://127.0.0.1:$Port/health"
if (-not [string]::IsNullOrWhiteSpace($defaultHtml)) {
  Write-Host "Default HTML file: $defaultHtml"
}

try {
  $listener.Start()
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      $method = $context.Request.HttpMethod.ToUpperInvariant()
      $path = $context.Request.Url.AbsolutePath

      # ----- API -----
      if ($path -eq '/api/state' -and $method -eq 'GET') {
        $data = Load-YCData
        $payload = if ($null -eq $data) {
          @{ seeded = $false }
        } else {
          @{ seeded = $true; data = $data }
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 64))
        $context.Response.StatusCode = 200
        $context.Response.ContentType = 'application/json; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.AddHeader('Cache-Control', 'no-store')
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()
        continue
      }

      if ($path -eq '/api/admin/configured' -and $method -eq 'GET') {
        $admin = Load-Admin
        $configured = $false
        if ($null -ne $admin) {
          if ($null -ne $admin.hash) { $configured = $true }
        }
        $payload = @{ configured = $configured } | ConvertTo-Json -Depth 10
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $context.Response.StatusCode = 200
        $context.Response.ContentType = 'application/json; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.AddHeader('Cache-Control', 'no-store')
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()
        continue
      }

      if ($path -eq '/api/admin/setPassword' -and $method -eq 'POST') {
        $body = Read-RequestBodyAsJson $context
        if ($null -eq $body) {
          Send-TextResponse $context 400 "Invalid JSON body."
          continue
        }
        $hash = $body.hash
        $email = $body.email
        $allowOverwrite = $false
        if ($body.allowOverwrite -eq $true) { $allowOverwrite = $true }

        if ([string]::IsNullOrWhiteSpace($hash)) {
          Send-TextResponse $context 400 "Missing 'hash'."
          continue
        }

        $adminExisting = Load-Admin
        $configuredAlready = $false
        if ($null -ne $adminExisting -and $null -ne $adminExisting.hash) { $configuredAlready = $true }

        if ($configuredAlready -and (-not $allowOverwrite)) {
          Send-TextResponse $context 403 "Admin already configured."
          continue
        }

        $adminObj = @{ hash = $hash; email = $email; updatedAt = (Get-Date).ToString("o") }
        $ok = Save-Admin $adminObj
        if (-not $ok) {
          Send-TextResponse $context 500 "Failed to persist admin password."
          continue
        }

        $bytes = [Text.Encoding]::UTF8.GetBytes((@{ ok = $true } | ConvertTo-Json -Depth 10))
        $context.Response.StatusCode = 200
        $context.Response.ContentType = 'application/json; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.AddHeader('Cache-Control', 'no-store')
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()
        continue
      }

      if ($path -eq '/api/admin/verify' -and $method -eq 'POST') {
        $body = Read-RequestBodyAsJson $context
        if ($null -eq $body) {
          Send-TextResponse $context 400 "Invalid JSON body."
          continue
        }
        $hash = $body.hash
        if ([string]::IsNullOrWhiteSpace($hash)) {
          Send-TextResponse $context 400 "Missing 'hash'."
          continue
        }

        $admin = Load-Admin
        $ok = $false
        $email = $null
        if ($null -ne $admin) {
          if ($null -ne $admin.hash) {
            $ok = ($admin.hash -eq $hash)
            if ($ok) { $email = $admin.email }
          }
        }
        $payload = @{ ok = $ok; email = $email } | ConvertTo-Json -Depth 10
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $context.Response.StatusCode = 200
        $context.Response.ContentType = 'application/json; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.AddHeader('Cache-Control', 'no-store')
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()
        continue
      }

      if ($path -eq '/api/saveState' -and $method -eq 'POST') {
        $body = Read-RequestBodyAsJson $context
        if ($null -eq $body) {
          Send-TextResponse $context 400 "Invalid JSON body."
          continue
        }
        $ok = Save-YCData $body
        if (-not $ok) {
          Send-TextResponse $context 500 "Failed to persist state."
          continue
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes((@{ ok = $true } | ConvertTo-Json -Depth 10))
        $context.Response.StatusCode = 200
        $context.Response.ContentType = 'application/json; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.AddHeader('Cache-Control', 'no-store')
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()
        continue
      }

      if ($path.StartsWith('/api/') -and $method -ne 'GET' -and $method -ne 'POST') {
        Send-TextResponse $context 405 "Method not allowed."
        continue
      }

      if ($method -ne 'GET') {
        Send-TextResponse $context 405 "Only GET (and POST /api/saveState) are supported."
        continue
      }

      if ($path -eq '/health') {
        $payload = @{ ok = $true; at = (Get-Date).ToString("o") } | ConvertTo-Json -Depth 2
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $context.Response.StatusCode = 200
        $context.Response.ContentType = 'application/json; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.AddHeader('Cache-Control', 'no-store')
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()
        continue
      }

      if ($path -eq '/' -or $path.EndsWith('/')) {
        Serve-DefaultHtml $context
        continue
      }

      $hasExtension = [IO.Path]::GetExtension($path).Length -gt 0
      $abs = Safe-ResolvePath $path
      if ($null -eq $abs) {
        Send-TextResponse $context 400 "Invalid path."
        continue
      }

      if (Serve-File $context $abs) { continue }

      # If the request doesn't look like a file (no extension), fall back to default HTML.
      if (-not $hasExtension) {
        Serve-DefaultHtml $context
        continue
      }

      Send-TextResponse $context 404 "Not found: $path"
    } catch {
      Send-TextResponse $context 500 "Server error."
    }
  }
} finally {
  if ($listener.IsListening) { $listener.Stop() }
}

