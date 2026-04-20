$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$venvDir = Join-Path $repoRoot '.venv'
$venvPython = Join-Path $venvDir 'Scripts\python.exe'

. $PSScriptRoot\native-env.ps1 -EnsureVenv -InstallPythonDeps

if (-not (Test-Path $venvPython)) {
  throw 'The project virtual environment could not be created.'
}

ghc --version
cabal --version
cabal update
cabal build all
cabal test
