<#
    serve.ps1 -- serve the board web pages on http://localhost:8000 and open one.

    Web Serial (how the page reaches COM9) only works in Chrome or Edge, and
    only on a secure origin -- localhost counts, a double-clicked file may not.

        .\fpga\web\serve.ps1                    # opens seg7_demo.html
        .\fpga\web\serve.ps1 -Page other.html
#>
param([string] $Page = "seg7_demo.html", [int] $Port = 8000)

$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')
$url = "http://localhost:$Port/$Page"

# prefer Chrome, then Edge: both support Web Serial
$browser = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LocalAppData\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

Write-Host "Serving $PSScriptRoot at http://localhost:$Port  (Ctrl+C to stop)"
if ($browser) { Start-Process $browser $url } else { Start-Process $url }
python -m http.server $Port --bind 127.0.0.1 --directory $PSScriptRoot
