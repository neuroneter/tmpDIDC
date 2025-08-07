param([string]$Command)

$PlinkPath = "plink"  # o la ruta completa si la conoces
$Username = "admwb"
$Password = "Cirion#617"
$DevServer = "172.16.4.4"
$StageServer = "172.16.5.4"

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

Write-Host "Ejecutando: $Command"
Write-Host ""

Invoke-PlinkCommand -Server $DevServer -Command $Command
Invoke-PlinkCommand -Server $StageServer -Command $Command