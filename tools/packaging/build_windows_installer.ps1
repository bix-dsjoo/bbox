param(
  [string]$InnoScript = "installer\bbox_labeler.iss",
  [switch]$SkipFlutterBuild
)

$ErrorActionPreference = "Stop"

function Find-Iscc {
  $command = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
  if ($null -ne $command) {
    return $command.Source
  }

  $candidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
  )

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  throw "Inno Setup compiler was not found. Install Inno Setup 6 or add ISCC.exe to PATH."
}

function Find-Flutter {
  $command = Get-Command "flutter.bat" -ErrorAction SilentlyContinue
  if ($null -ne $command) {
    return $command.Source
  }

  $candidates = @(
    "C:\tools\flutter\bin\flutter.bat",
    "$env:LOCALAPPDATA\flutter\bin\flutter.bat"
  )

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  throw "Flutter was not found. Add flutter.bat to PATH or install it at C:\tools\flutter."
}

$manifestRelativePath = "models\bread_pipeline_manifest.json"
$manifestPath = Join-Path (Get-Location).Path $manifestRelativePath
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "Required pipeline manifest was not found at $manifestPath."
}
$pipelineManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
foreach ($modelFile in @(
    [string]$pipelineManifest.detector.file,
    [string]$pipelineManifest.classifier.file
  )) {
  if (-not $modelFile.EndsWith(".pt") -or [System.IO.Path]::GetFileName($modelFile) -ne $modelFile) {
    throw "Pipeline manifest contains an unsafe model filename: $modelFile"
  }
}

$requiredAssetPaths = @(
  "runtime\python\python.exe",
  "tools\detectors\bread_box_worker.py",
  $manifestRelativePath,
  ("models\" + [string]$pipelineManifest.detector.file),
  ("models\" + [string]$pipelineManifest.classifier.file)
)

foreach ($requiredPath in $requiredAssetPaths) {
  $absoluteRequiredPath = Join-Path (Get-Location).Path $requiredPath
  if (-not (Test-Path -LiteralPath $absoluteRequiredPath)) {
    throw "Required automatic-box asset was not found at $absoluteRequiredPath. Prepare the bundled detector runtime and model before building the installer."
  }
}

if (-not $SkipFlutterBuild) {
  $flutter = Find-Flutter
  & $flutter build windows --release
  if ($LASTEXITCODE -ne 0) {
    throw "Flutter Windows release build failed with exit code $LASTEXITCODE"
  }
}

$releaseRoot = Join-Path (Get-Location).Path "build\windows\x64\runner\Release"
foreach ($requiredPath in $requiredAssetPaths) {
  $absoluteReleaseRequiredPath = Join-Path $releaseRoot $requiredPath
  if (-not (Test-Path -LiteralPath $absoluteReleaseRequiredPath)) {
    throw "Required release asset was not found at $absoluteReleaseRequiredPath. Run the Flutter Windows release build after preparing the bundled detector runtime and model."
  }
}

$releaseModelVerifier = Join-Path (Get-Location).Path "tools\packaging\verify_release_models.ps1"
& $releaseModelVerifier -ReleaseRoot $releaseRoot

foreach ($forbiddenLegacyAssetPath in @(
    ("tools\detectors\fast" + "sam_detector.py"),
    ("tools\detectors\bread_" + "vision_detector.py")
  )) {
  $absoluteForbiddenPath = Join-Path $releaseRoot $forbiddenLegacyAssetPath
  if (Test-Path -LiteralPath $absoluteForbiddenPath) {
    throw "Release contains a forbidden legacy detector asset: $absoluteForbiddenPath"
  }
}

foreach ($folderName in @("train", "datasets", "outputs", "qa_samples", "research", "build", "dist")) {
  $folderPath = Join-Path $releaseRoot $folderName
  if (Test-Path -LiteralPath $folderPath) {
    throw "Release root contains development-only folder: $folderPath"
  }
}

$iscc = Find-Iscc
& $iscc $InnoScript
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup build failed with exit code $LASTEXITCODE"
}

Write-Host "Installer build complete."
