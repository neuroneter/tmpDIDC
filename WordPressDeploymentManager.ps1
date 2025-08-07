
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("pre-check", "migrate", "rollback-complete", "status")]
    [string]$Operation,
    
    [Parameter(Mandatory=$false)]
    [string]$MigrationId
)

# Configuracion
$DevServer = "172.16.4.4"
$StageServer = "172.16.5.4"
$Username = "admwb"
$Password = "Cirion#617"
$DevPath = "/var/www/html/debweb"
$StagePath = "/var/www/html/webcirion"
$ScriptPath = "C:\Scripts\WordPress"

# Buscar plink
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

function Write-ColorLog {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Invoke-SSHCommand {
    param([string]$Server, [string]$Command)
    
    if (-not $PlinkPath) {
        Write-ColorLog "ERROR: plink no encontrado" "Red"
        return $null
    }
    
    $plinkArgs = @("-ssh", "-pw", $Password, "-batch", "$Username@$Server", $Command)
    $result = & $PlinkPath $plinkArgs 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        return $result
    } else {
        return $null
    }
}

function Test-Connectivity {
    Write-ColorLog "Verificando conectividad..." "Yellow"
    
    # Test Dev
    if (Test-Connection -ComputerName $DevServer -Count 1 -Quiet) {
        Write-ColorLog "Dev server: OK" "Green"
    } else {
        Write-ColorLog "Dev server: FALLO" "Red"
        return $false
    }
    
    # Test Stage  
    if (Test-Connection -ComputerName $StageServer -Count 1 -Quiet) {
        Write-ColorLog "Stage server: OK" "Green"
    } else {
        Write-ColorLog "Stage server: FALLO" "Red"
        return $false
    }
    
    # Test SSH Dev
    $testDev = Invoke-SSHCommand -Server $DevServer -Command "echo test"
    if ($testDev) {
        Write-ColorLog "SSH Dev: OK" "Green"
    } else {
        Write-ColorLog "SSH Dev: FALLO" "Red"
        return $false
    }
    
    # Test SSH Stage
    $testStage = Invoke-SSHCommand -Server $StageServer -Command "echo test"
    if ($testStage) {
        Write-ColorLog "SSH Stage: OK" "Green"
    } else {
        Write-ColorLog "SSH Stage: FALLO" "Red"
        return $false
    }
    
    return $true
}

function Show-Status {
    Write-ColorLog "=== ESTADO DEL SISTEMA ===" "Cyan"
    
    # Espacio libre Stage
    $spaceResult = Invoke-SSHCommand -Server $StageServer -Command "df /tmp | tail -1 | awk '{print int(`$4/1024)}'"
    if ($spaceResult) {
        $spaceMB = $spaceResult.Trim()
        Write-ColorLog "Espacio libre Stage: ${spaceMB}MB" "Green"
    }
    
    # Backups BD
    $dbBackups = Invoke-SSHCommand -Server $StageServer -Command "ls /tmp/stage_safety_backup_*.sql 2>/dev/null | wc -l"
    if ($dbBackups) {
        Write-ColorLog "BD Backups: $($dbBackups.Trim())" "Green"
    }
    
    # Backups Uploads
    $uploadsBackups = Invoke-SSHCommand -Server $StageServer -Command "ls /tmp/stage_uploads_backup_*.tar.gz 2>/dev/null | wc -l"
    if ($uploadsBackups) {
        Write-ColorLog "Uploads Backups: $($uploadsBackups.Trim())" "Green"
    }
    
    # Listar backups recientes
    Write-ColorLog "Backups recientes:" "Cyan"
    $recentBackups = Invoke-SSHCommand -Server $StageServer -Command "ls -lt /tmp/stage_*backup_*.* 2>/dev/null | head -5"
    if ($recentBackups) {
        $recentBackups -split "`n" | ForEach-Object {
            if ($_.Trim()) {
                Write-ColorLog "  $_" "White"
            }
        }
    }
}

function Test-WordPress {
    param([string]$Server, [string]$Path, [string]$EnvName)
    
    Write-ColorLog "Verificando WordPress $EnvName..." "Yellow"
    
    $wpTest = Invoke-SSHCommand -Server $Server -Command "cd $Path && wp core is-installed"
    if ($wpTest -ne $null) {
        Write-ColorLog "$EnvName WordPress: OK" "Green"
        return $true
    } else {
        Write-ColorLog "$EnvName WordPress: FALLO" "Red"
        return $false
    }
}

function Execute-PreCheck {
    Write-ColorLog "=== PRE-CHECK COMPLETO ===" "Cyan"
    
    if (-not (Test-WordPress -Server $DevServer -Path $DevPath -EnvName "Development")) {
        return $false
    }
    
    if (-not (Test-WordPress -Server $StageServer -Path $StagePath -EnvName "Stage")) {
        return $false
    }
    
    Write-ColorLog "SUCCESS: Sistema listo para migracion" "Green"
    return $true
}

function Copy-Script {
    Write-ColorLog "Copiando script de migracion..." "Yellow"
    
    $PscpPath = $PlinkPath -replace "plink", "pscp"
    if ($PlinkPath -eq "plink") {
        $PscpPath = "pscp"
    }
    
    $scriptFile = "$ScriptPath\migrate-dev-to-stage.sh"
    if (-not (Test-Path $scriptFile)) {
        Write-ColorLog "ERROR: Script no encontrado" "Red"
        return $false
    }
    
    $pscpArgs = @("-pw", $Password, "-batch", $scriptFile, "$Username@${DevServer}:/tmp/")
    $result = & $PscpPath $pscpArgs 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        # Hacer ejecutable
        Invoke-SSHCommand -Server $DevServer -Command "chmod +x /tmp/migrate-dev-to-stage.sh" | Out-Null
        Write-ColorLog "Script copiado exitosamente" "Green"
        return $true
    } else {
        Write-ColorLog "ERROR copiando script" "Red"
        return $false
    }
}

function Execute-Migration {
    Write-ColorLog "=== EJECUTANDO MIGRACION ===" "Cyan"
    Write-ColorLog "Esto puede tomar varios minutos..." "Yellow"
    
    $migrateCommand = "cd /tmp && ./migrate-dev-to-stage.sh"
    $result = Invoke-SSHCommand -Server $DevServer -Command $migrateCommand
    
    if ($result) {
        Write-ColorLog "SUCCESS: Migracion completada" "Green"
        
        # Buscar Migration ID
        $lines = $result -split "`n"
        foreach ($line in $lines) {
            if ($line -match "Migration ID: (\w+)") {
                $migrationId = $matches[1]
                Write-ColorLog "Migration ID: $migrationId" "Green"
                Write-ColorLog "Para rollback: -Operation rollback-complete -MigrationId $migrationId" "Yellow"
                break
            }
        }
        
        # Verificar sitio
        Test-Website
        return $true
    } else {
        Write-ColorLog "ERROR: Migracion fallo" "Red"
        return $false
    }
}

function Execute-Rollback {
    param([string]$MigrationId)
    
    if (-not $MigrationId) {
        Write-ColorLog "ERROR: Migration ID requerido" "Red"
        Show-Status
        return $false
    }
    
    Write-ColorLog "=== ROLLBACK COMPLETO ===" "Red"
    Write-ColorLog "Migration ID: $MigrationId" "Yellow"
    
    # Verificar backups existen
    $dbExists = Invoke-SSHCommand -Server $StageServer -Command "test -f /tmp/stage_safety_backup_$MigrationId.sql && echo yes || echo no"
    if ($dbExists.Trim() -ne "yes") {
        Write-ColorLog "ERROR: Backup BD no encontrado" "Red"
        return $false
    }
    
    # Rollback BD
    Write-ColorLog "Restaurando base de datos..." "Yellow"
    $dbRollback = Invoke-SSHCommand -Server $StageServer -Command "cd $StagePath && wp db import /tmp/stage_safety_backup_$MigrationId.sql"
    if (-not $dbRollback) {
        Write-ColorLog "ERROR: Fallo rollback BD" "Red"
        return $false
    }
    
    # Rollback Uploads (si existe)
    $uploadsExists = Invoke-SSHCommand -Server $StageServer -Command "test -f /tmp/stage_uploads_backup_$MigrationId.tar.gz && echo yes || echo no"
    if ($uploadsExists.Trim() -eq "yes") {
        Write-ColorLog "Restaurando uploads..." "Yellow"
        $uploadsRollback = Invoke-SSHCommand -Server $StageServer -Command "cd $StagePath/wp-content && rm -rf uploads && tar -xzf /tmp/stage_uploads_backup_$MigrationId.tar.gz"
        if ($uploadsRollback -ne $null) {
            Write-ColorLog "Uploads restaurados" "Green"
        }
    }
    
    Write-ColorLog "SUCCESS: Rollback completo exitoso" "Green"
    Test-Website
    return $true
}

function Test-Website {
    Write-ColorLog "Verificando sitio web..." "Yellow"
    
    $uri = "https://web3stg.ciriontechnologies.com"
    $response = Invoke-WebRequest -Uri $uri -Method HEAD -TimeoutSec 30 -ErrorAction SilentlyContinue
    
    if ($response -and $response.StatusCode -eq 200) {
        Write-ColorLog "Sitio web: OK (HTTP 200)" "Green"
    } else {
        Write-ColorLog "Sitio web: Problema de acceso" "Red"
    }
}

# MAIN EXECUTION
Write-ColorLog "============================================" "White"
Write-ColorLog "WordPress Deployment Manager - SIMPLE" "Cyan"
Write-ColorLog "============================================" "White"
Write-ColorLog "Operacion: $Operation" "White"
Write-ColorLog "plink: $PlinkPath" "White"
Write-ColorLog "Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "White"
Write-ColorLog "============================================" "White"

if (-not $PlinkPath) {
    Write-ColorLog "ERROR: plink no encontrado. Instalar PuTTY" "Red"
    exit 1
}

# Verificar conectividad para operaciones que la necesitan
if ($Operation -ne "rollback-complete" -or -not $MigrationId) {
    if (-not (Test-Connectivity)) {
        Write-ColorLog "ERROR: Fallo conectividad" "Red"
        exit 1
    }
}

# Ejecutar operacion
if ($Operation -eq "status") {
    Show-Status
    exit 0
}

if ($Operation -eq "pre-check") {
    if (Execute-PreCheck) {
        exit 0
    } else {
        exit 1
    }
}

if ($Operation -eq "migrate") {
    # Pre-check
    if (-not (Execute-PreCheck)) {
        Write-ColorLog "ERROR: Pre-check fallo" "Red"
        exit 1
    }
    
    # Copiar script
    if (-not (Copy-Script)) {
        Write-ColorLog "ERROR: Fallo copiando script" "Red"
        exit 1
    }
    
    # Migrar
    if (Execute-Migration) {
        Write-ColorLog "SUCCESS: Migracion exitosa" "Green"
        exit 0
    } else {
        Write-ColorLog "ERROR: Migracion fallo" "Red"
        exit 1
    }
}

if ($Operation -eq "rollback-complete") {
    if (Execute-Rollback -MigrationId $MigrationId) {
        Write-ColorLog "SUCCESS: Rollback exitoso" "Green"
        exit 0
    } else {
        Write-ColorLog "ERROR: Rollback fallo" "Red"
        exit 1
    }
}

Write-ColorLog "Operacion completada" "Green"