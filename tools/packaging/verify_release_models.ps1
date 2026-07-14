param(
  [Parameter(Mandatory = $true)]
  [string]$ReleaseRoot
)

$ErrorActionPreference = "Stop"
$releaseRoot = [System.IO.Path]::GetFullPath($ReleaseRoot)
$manifestPath = Join-Path $releaseRoot "models\bread_pipeline_manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "Required release pipeline manifest was not found: $manifestPath"
}
$pipelineManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
foreach ($modelFile in @(
    [string]$pipelineManifest.detector.file,
    [string]$pipelineManifest.classifier.file
  )) {
  if (-not $modelFile.EndsWith(".pt") -or [System.IO.Path]::GetFileName($modelFile) -ne $modelFile) {
    throw "Release pipeline manifest contains an unsafe model filename: $modelFile"
  }
}
$allowedReleaseModelPaths = @(
  [System.IO.Path]::GetFullPath(
    (Join-Path $releaseRoot ("models\" + [string]$pipelineManifest.detector.file))
  ),
  [System.IO.Path]::GetFullPath(
    (Join-Path $releaseRoot ("models\" + [string]$pipelineManifest.classifier.file))
  )
)

foreach ($allowedPath in $allowedReleaseModelPaths) {
  if (-not (Test-Path -LiteralPath $allowedPath -PathType Leaf)) {
    throw "Required release pipeline model was not found: $allowedPath"
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
