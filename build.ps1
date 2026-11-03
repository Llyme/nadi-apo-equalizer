# Builds the Equalizer plugin: its helper (Rust), its tests, and the file a release carries (nadi-plugins.tar.gz: the plugin's folder).
#
# Needs Rust (cargo). The tests run when `nadi-plugin` (the test runner that comes with NADI) is on the PATH or named by $env:NADI_PLUGIN.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
try {
  # its helper, into the plugin's bin/
  Push-Location (Join-Path $here "helper")
  try {
    cargo build --release
    if ($LASTEXITCODE -ne 0) { throw "the helper did not build" }
  } finally { Pop-Location }
  $bin = Join-Path $here "apo-equalizer\bin"
  New-Item -ItemType Directory -Force $bin | Out-Null
  Copy-Item (Join-Path $here "helper\target\release\apo-helper.exe") $bin -Force

  # its tests
  $runner = $env:NADI_PLUGIN
  if (-not $runner) { $found = Get-Command nadi-plugin -ErrorAction SilentlyContinue; if ($found) { $runner = $found.Source } }
  if ($runner) {
    & $runner test (Join-Path $here "apo-equalizer")
    if ($LASTEXITCODE -ne 0) { throw "tests failed" }
  } else {
    "nadi-plugin not found: tests skipped"
  }

  # the release's file: the plugin's folder, without its tests
  $dist = Join-Path $here "dist"
  if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
  $to = Join-Path $dist "apo-equalizer"
  New-Item -ItemType Directory -Force $to | Out-Null
  Copy-Item (Join-Path $here "apo-equalizer\manifest.json"), (Join-Path $here "apo-equalizer\main.luau") $to
  Copy-Item $bin (Join-Path $to "bin") -Recurse
  & "$env:SystemRoot\System32\tar.exe" -czf (Join-Path $here "nadi-plugins.tar.gz") -C $dist .
  Get-ChildItem $to -Recurse -File | ForEach-Object { "dist/{0}  {1:N0} bytes" -f $_.FullName.Substring($dist.Length + 1), $_.Length }
  "nadi-plugins.tar.gz"
} finally { Pop-Location }
