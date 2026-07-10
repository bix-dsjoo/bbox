param(
  [string]$PythonVersion = "3.12.8",
  [string]$TorchVersion = "2.5.1",
  [string]$TorchVisionVersion = "0.20.1",
  [string]$UltralyticsVersion = "8.3.40",
  [string]$OpenCvVersion = "4.10.0.84",
  [string]$NumpyVersion = "1.26.4",
  [string]$MatplotlibVersion = "3.10.5",
  [string]$PyYamlVersion = "6.0.2",
  [string]$RequestsVersion = "2.32.3",
  [string]$ScipyVersion = "1.14.1",
  [string]$TqdmVersion = "4.67.1",
  [string]$PsutilVersion = "6.1.0",
  [string]$PyCpuInfoVersion = "9.0.0",
  [string]$PandasVersion = "2.2.3",
  [string]$SeabornVersion = "0.13.2",
  [string]$UltralyticsThopVersion = "2.0.12",
  [string]$RuntimeDir = "runtime\python",
  [string]$CacheDir = "build\detector_runtime_cache",
  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path (Get-Location).Path $Path
}

function Download-File([string]$Url, [string]$OutFile) {
  Write-Host "Downloading $Url"
  Invoke-WebRequest -Uri $Url -OutFile $OutFile
}

$runtimePath = Resolve-RepoPath $RuntimeDir
$cachePath = Resolve-RepoPath $CacheDir
$pythonExe = Join-Path $runtimePath "python.exe"
$zipName = "python-$PythonVersion-embed-amd64.zip"
$zipPath = Join-Path $cachePath $zipName
$pythonUrl = "https://www.python.org/ftp/python/$PythonVersion/$zipName"
$getPipPath = Join-Path $cachePath "get-pip.py"
$getPipUrl = "https://bootstrap.pypa.io/get-pip.py"

if ((Test-Path -LiteralPath $runtimePath) -and -not $Force) {
  throw "Runtime directory already exists: $runtimePath. Use -Force to recreate it."
}

if (Test-Path -LiteralPath $runtimePath) {
  Remove-Item -LiteralPath $runtimePath -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $runtimePath | Out-Null
New-Item -ItemType Directory -Force -Path $cachePath | Out-Null

if (-not (Test-Path -LiteralPath $zipPath)) {
  Download-File -Url $pythonUrl -OutFile $zipPath
}

Expand-Archive -LiteralPath $zipPath -DestinationPath $runtimePath -Force

$pthFile = Get-ChildItem -LiteralPath $runtimePath -Filter "python*._pth" | Select-Object -First 1
if ($null -eq $pthFile) {
  throw "Could not find Python embeddable ._pth file in $runtimePath"
}

$pthContent = Get-Content -LiteralPath $pthFile.FullName
$pthContent = $pthContent | ForEach-Object {
  if ($_ -eq "#import site") { "import site" } else { $_ }
}
Set-Content -LiteralPath $pthFile.FullName -Value $pthContent -Encoding ASCII

if (-not (Test-Path -LiteralPath $getPipPath)) {
  Download-File -Url $getPipUrl -OutFile $getPipPath
}

& $pythonExe $getPipPath --no-warn-script-location
if ($LASTEXITCODE -ne 0) {
  throw "pip bootstrap failed with exit code $LASTEXITCODE"
}

& $pythonExe -m pip install --no-warn-script-location --upgrade pip
if ($LASTEXITCODE -ne 0) {
  throw "pip upgrade failed with exit code $LASTEXITCODE"
}

& $pythonExe -m pip install --no-warn-script-location `
  --index-url https://download.pytorch.org/whl/cpu `
  "torch==$TorchVersion" "torchvision==$TorchVisionVersion"
if ($LASTEXITCODE -ne 0) {
  throw "CPU PyTorch install failed with exit code $LASTEXITCODE"
}

& $pythonExe -m pip install --no-warn-script-location `
  "numpy==$NumpyVersion" `
  "opencv-python-headless==$OpenCvVersion" `
  "matplotlib==$MatplotlibVersion" `
  "pyyaml==$PyYamlVersion" `
  "requests==$RequestsVersion" `
  "scipy==$ScipyVersion" `
  "tqdm==$TqdmVersion" `
  "psutil==$PsutilVersion" `
  "py-cpuinfo==$PyCpuInfoVersion" `
  "pandas==$PandasVersion" `
  "seaborn==$SeabornVersion" `
  "ultralytics-thop==$UltralyticsThopVersion"
if ($LASTEXITCODE -ne 0) {
  throw "detector dependency install failed with exit code $LASTEXITCODE"
}

& $pythonExe -m pip install --no-warn-script-location --no-deps "ultralytics==$UltralyticsVersion"
if ($LASTEXITCODE -ne 0) {
  throw "Ultralytics install failed with exit code $LASTEXITCODE"
}

$env:PYTHONDONTWRITEBYTECODE = "1"
& $pythonExe -c "import torch, torchvision, cv2, numpy, ultralytics; print('detector runtime ok'); print('torch', torch.__version__); print('torchvision', torchvision.__version__); print('cv2', cv2.__version__); print('numpy', numpy.__version__); print('ultralytics', ultralytics.__version__)"
if ($LASTEXITCODE -ne 0) {
  throw "detector runtime smoke test failed with exit code $LASTEXITCODE"
}

Get-ChildItem -LiteralPath $runtimePath -Recurse -Directory -Force |
  Where-Object { $_.Name -in @("__pycache__", "test", "tests") } |
  Sort-Object FullName -Descending |
  Remove-Item -Recurse -Force

Get-ChildItem -LiteralPath $runtimePath -Recurse -File -Force |
  Where-Object { $_.Extension -in @(".pyc", ".pyo", ".whl") } |
  Remove-Item -Force

Write-Host "Detector runtime prepared at $runtimePath"
Write-Host "Pinned packages: torch==$TorchVersion, torchvision==$TorchVisionVersion, ultralytics==$UltralyticsVersion, opencv-python-headless==$OpenCvVersion, numpy==$NumpyVersion"
