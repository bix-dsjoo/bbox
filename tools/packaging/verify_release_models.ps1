param(
  [Parameter(Mandatory = $true)]
  [string]$ReleaseRoot
)

$ErrorActionPreference = "Stop"
$releaseRoot = [System.IO.Path]::GetFullPath($ReleaseRoot)
$allowedReleaseModelPaths = @(
  [System.IO.Path]::GetFullPath(
    (Join-Path $releaseRoot "models\bread_yolov8n_1class_tray_v0_2.pt")
  )
)

foreach ($allowedPath in $allowedReleaseModelPaths) {
  if (-not (Test-Path -LiteralPath $allowedPath -PathType Leaf)) {
    throw "Required release detector model was not found: $allowedPath"
  }
}

$releaseModelFiles = @(
  Get-ChildItem -LiteralPath $releaseRoot -Filter "*.pt" -File -Recurse -ErrorAction SilentlyContinue
)
$unexpectedReleaseModels = @(
  $releaseModelFiles | Where-Object {
    $allowedReleaseModelPaths -notcontains [System.IO.Path]::GetFullPath($_.FullName)
  }
)
if ($unexpectedReleaseModels.Count -gt 0) {
  $unexpectedPaths = $unexpectedReleaseModels.FullName -join ", "
  throw "Release contains an unexpected detector model: $unexpectedPaths"
}
