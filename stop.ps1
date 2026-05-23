$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppPath = Join-Path $ProjectRoot "app.py"

$processes = Get-CimInstance Win32_Process |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine -like "*streamlit*" -and
        $_.CommandLine -like "*$AppPath*"
    }

if ($processes) {
    foreach ($process in $processes) {
        Write-Host "Stopping app process $($process.ProcessId)..."
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        } catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
            Write-Host "App process $($process.ProcessId) already exited."
        }
    }
} else {
    Write-Host "No running app process found."
}

$ollamaProcesses = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
if ($ollamaProcesses) {
    foreach ($process in $ollamaProcesses) {
        Write-Host "Stopping Ollama process $($process.Id)..."
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        } catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
            Write-Host "Ollama process $($process.Id) already exited."
        }
    }
} else {
    Write-Host "No running Ollama process found."
}

Start-Sleep -Milliseconds 500
$remainingOllamaProcesses = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
if ($remainingOllamaProcesses) {
    try {
        $remainingOllamaProcesses | Stop-Process -Force -ErrorAction Stop
    } catch {
    }
}

Write-Host "App and Ollama stopped."
