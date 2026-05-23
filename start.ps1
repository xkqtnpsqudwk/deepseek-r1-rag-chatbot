param(
    [switch]$NoBrowser,
    [string]$Model = "deepseek-r1:7b",
    [string]$OllamaBaseUrl = "http://localhost:11434"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppPath = Join-Path $ProjectRoot "app.py"
$VenvPython = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
$Streamlit = Join-Path $ProjectRoot ".venv\Scripts\streamlit.exe"
$Port = 8501

Set-Location $ProjectRoot
$OllamaBaseUrl = $OllamaBaseUrl.TrimEnd("/")

function Test-Ollama {
    try {
        Invoke-RestMethod -Uri "$OllamaBaseUrl/api/tags" -TimeoutSec 2 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Clear-StoppingOllamaRunners {
    param([string]$OllamaExe)

    try {
        $runningModels = (& $OllamaExe ps 2>$null) | Out-String
        if ($runningModels -notmatch "Stopping") {
            return
        }

        Write-Host "Found a stuck Ollama runner. Cleaning it up..."
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -like "*ollama.exe*" -and
                $_.CommandLine -like "*runner*"
            } |
            ForEach-Object {
                try {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
                } catch {
                }
            }
        Start-Sleep -Seconds 2
    } catch {
    }
}

function Test-PythonCommand {
    param([string]$PythonExe)

    if (-not $PythonExe -or -not (Test-Path $PythonExe)) {
        return $false
    }

    try {
        & $PythonExe -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Find-Python {
    $candidates = @()

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        foreach ($version in @("-3.12", "-3")) {
            try {
                $resolved = (& $pyLauncher.Source $version -c "import sys; print(sys.executable)" 2>$null) | Select-Object -First 1
                if ($LASTEXITCODE -eq 0 -and $resolved) {
                    $candidates += $resolved
                }
            } catch {
            }
        }
    }

    foreach ($commandName in @("python", "python3")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) {
            $candidates += $command.Source
        }
    }

    $candidates += @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"),
        (Join-Path $env:ProgramFiles "Python312\python.exe")
    )

    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-PythonCommand $candidate) {
            return $candidate
        }
    }

    return $null
}

function Install-Python {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Host "Python 3.10+ is required, but Python and winget were not found."
        Write-Host "Install Python from: https://www.python.org/downloads/windows/"
        exit 1
    }

    Write-Host "Python was not found. Installing Python 3.12 with winget..."
    & $winget.Source install --id Python.Python.3.12 -e --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Python installation failed. Install Python manually from: https://www.python.org/downloads/windows/"
        exit 1
    }

    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

if (-not (Test-Path $VenvPython)) {
    $PythonExe = Find-Python
    if (-not $PythonExe) {
        Install-Python
        $PythonExe = Find-Python
    }

    if (-not $PythonExe) {
        Write-Host "Python was installed, but this shell could not find it yet."
        Write-Host "Close this window and run start.bat again."
        exit 1
    }

    Write-Host "Using Python: $PythonExe"
    Write-Host "Creating virtual environment..."
    & $PythonExe -m venv .venv
}

$needsInstall = -not (Test-Path $Streamlit)
if (-not $needsInstall) {
    & $VenvPython -c "import langchain_ollama" 2>$null
    if ($LASTEXITCODE -ne 0) {
        $needsInstall = $true
    }
}

if ($needsInstall) {
    Write-Host "Installing dependencies..."
    & $VenvPython -m pip install -r requirements.txt
}

$ollamaCommand = Get-Command ollama -ErrorAction SilentlyContinue
$ollamaExe = if ($ollamaCommand) { $ollamaCommand.Source } else { Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe" }
if (-not (Test-Path $ollamaExe)) {
    Write-Host "Ollama is required for local DeepSeek-R1."
    Write-Host "Install it from: https://ollama.com/download"
    exit 1
}

if (-not (Test-Ollama)) {
    Write-Host "Starting Ollama server..."
    Start-Process -WindowStyle Hidden -FilePath $ollamaExe -ArgumentList "serve"
    $ollamaReady = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Ollama) {
            $ollamaReady = $true
            break
        }
    }
    if (-not $ollamaReady) {
        Write-Host "Ollama server did not become ready at $OllamaBaseUrl."
        exit 1
    }
}

$existing = Get-CimInstance Win32_Process |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine -like "*streamlit*" -and
        $_.CommandLine -like "*$AppPath*"
    }

if ($existing) {
    Write-Host "App is already running at http://localhost:$Port"
    if (-not $NoBrowser) {
        Start-Process "http://localhost:$Port"
    }
    exit 0
}

Clear-StoppingOllamaRunners -OllamaExe $ollamaExe

$installedModels = (Invoke-RestMethod -Uri "$OllamaBaseUrl/api/tags" -TimeoutSec 5).models
$modelExists = $installedModels | Where-Object { $_.name -eq $Model }
if (-not $modelExists) {
    Write-Host "Pulling local model: $Model"
    & $ollamaExe pull $Model
}

$env:OLLAMA_MODEL = $Model
$env:OLLAMA_BASE_URL = $OllamaBaseUrl

Write-Host "Starting DeepSeek-R1 RAG Chatbot..."
Write-Host "Open: http://localhost:$Port"
if (-not $NoBrowser) {
    Start-Process "http://localhost:$Port"
}
& $Streamlit run $AppPath --server.port $Port --server.headless true --browser.gatherUsageStats false
