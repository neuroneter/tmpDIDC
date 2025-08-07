param([string]$Command)

# MISMA CONFIGURACIÓN QUE WordPressDeploymentManager.ps1
$DevServer = "172.16.4.4"
$StageServer = "172.16.5.4"
$Username = "admwb"
$Password = "Cirion#617"
$DevPath = "/var/www/html/debweb"
$StagePath = "/var/www/html/webcirion"

# Buscar plink con la misma lógica que el manager
$PlinkPath = $null
$PlinkLocations = @(
    "plink",
    "C:\Program Files\PuTTY\plink.exe",
    "C:\Program Files (x86)\PuTTY\plink.exe"
)

foreach ($loc in $PlinkLocations) {
    if ($loc -eq "plink") {
        $result = Get-Command plink -ErrorAction SilentlyContinue
        if ($result) {
            $PlinkPath = "plink"
            break
        }
    } else {
        if (Test-Path $loc) {
            $PlinkPath = $loc
            break
        }
    }
}

function Invoke-PlinkCommand {
    param([string]$Server, [string]$Command)
    
    try {
        $plinkArgs = @("-ssh", "-pw", $Password, "-batch", "$Username@$Server", $Command)
        $result = & $PlinkPath $plinkArgs 2>&1
        $exitCode = $LASTEXITCODE
        
        Write-Host "=== Resultado para $Server ==="
        Write-Host $result
        Write-Host "Exit Code: $exitCode"
        Write-Host ""
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)"
    }
}

Write-Host "Ejecutando: $Command" -ForegroundColor Yellow
Write-Host "plink: $PlinkPath" -ForegroundColor Green
Write-Host ""

Invoke-PlinkCommand -Server $DevServer -Command $Command
Invoke-PlinkCommand -Server $StageServer -Command $Command