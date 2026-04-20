param(
  [switch]$EnsureVenv,
  [switch]$InstallPythonDeps
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$ghcupRoot = Join-Path $env:USERPROFILE 'ghcup'
$cabalRoot = Join-Path $env:USERPROFILE 'cabal'
$venvDir = Join-Path $repoRoot '.venv'
$venvScripts = Join-Path $venvDir 'Scripts'
$venvPython = Join-Path $venvScripts 'python.exe'
$pathEntries = @(
  $venvScripts,
  (Join-Path $ghcupRoot 'bin'),
  (Join-Path $cabalRoot 'bin'),
  (Join-Path $ghcupRoot 'msys64\mingw64\bin'),
  (Join-Path $ghcupRoot 'msys64\usr\bin')
)

foreach ($entry in $pathEntries) {
  if ((Test-Path $entry) -and -not (($env:PATH -split ';') -contains $entry)) {
    $env:PATH = "$entry;$env:PATH"
  }
}

function Import-RepoEnvFile {
  param(
    [string]$Path
  )

  if (-not (Test-Path $Path)) {
    return
  }

  foreach ($rawLine in Get-Content $Path) {
    $line = $rawLine.Trim()
    if (-not $line -or $line.StartsWith('#')) {
      continue
    }

    if ($line.StartsWith('export ')) {
      $line = $line.Substring(7).Trim()
    }

    $separatorIndex = $line.IndexOf('=')
    if ($separatorIndex -lt 1) {
      continue
    }

    $name = $line.Substring(0, $separatorIndex).Trim()
    $value = $line.Substring($separatorIndex + 1).Trim()
    if (
      ($value.Length -ge 2) -and (
        ($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))
      )
    ) {
      $value = $value.Substring(1, $value.Length - 2)
    }

    if (-not $name) {
      continue
    }

    $existingValue = [Environment]::GetEnvironmentVariable($name, 'Process')
    if ($null -eq $existingValue -or $existingValue -eq '') {
      Set-Item -Path "Env:$name" -Value $value
    }
  }
}

Set-Location $repoRoot
Import-RepoEnvFile (Join-Path $repoRoot '.env')

if ((Test-Path $venvPython) -and -not [Environment]::GetEnvironmentVariable('FAITHFUL_PYTHON', 'Process')) {
  Set-Item -Path 'Env:FAITHFUL_PYTHON' -Value $venvPython
}

if (-not (Get-Command ghc -ErrorAction SilentlyContinue)) {
  throw 'ghc was not found on PATH. Install GHCup first.'
}

if (-not (Get-Command cabal -ErrorAction SilentlyContinue)) {
  throw 'cabal was not found on PATH. Install GHCup first.'
}

if ($EnsureVenv -and -not (Test-Path $venvPython)) {
  if (Get-Command py -ErrorAction SilentlyContinue) {
    & py -3 -m venv $venvDir
  } elseif (Get-Command python -ErrorAction SilentlyContinue) {
    & python -m venv $venvDir
  } else {
    throw 'Python 3 was not found on PATH.'
  }
}

if ($InstallPythonDeps) {
  if (-not (Test-Path $venvPython)) {
    throw 'The project virtual environment is missing. Run with -EnsureVenv first.'
  }

  & $venvPython -m pip install --upgrade pip
  & $venvPython -m pip install -r (Join-Path $repoRoot 'requirements-dev.txt')
}

Write-Output "Repo root: $repoRoot"
Write-Output "GHC: $((Get-Command ghc).Source)"
Write-Output "Cabal: $((Get-Command cabal).Source)"
if (Test-Path $venvPython) {
  Write-Output "Python: $venvPython"
}
