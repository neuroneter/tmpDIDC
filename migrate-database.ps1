param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("pre-check", "backup", "migrate", "rollback", "status", "verify", "list-backups")]
    [string]$Operation,
    
    [Parameter(Mandatory=$false)]
    [string]$MigrationId,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

# CONFIGURACION
$DevServer = "172.16.4.4"
$StageServer = "172.16.5.4"
$Username = "admwb"
$Password = "Cirion#617"
$DevPath = "/var/www/html/debweb"
$StagePath = "/var/www/html/webcirion"
$LogDir = "C:\Scripts\WordPress\Logs"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Buscar plink
$PlinkPath = $null
$PlinkLocations = @("plink", "C:\Program Files\PuTTY\plink.exe", "C:\Program Files (x86)\PuTTY\plink.exe")

foreach ($loc in $PlinkLocations) {
    if ($loc -eq "plink") {
        $result = Get-Command plink -ErrorAction SilentlyContinue
        if ($result) { $PlinkPath = "plink"; break }
    } else {
        if (Test-Path $loc) { $PlinkPath = $loc; break }
    }
}

# FUNCIONES BASICAS
function Write-ColorLog {
    param([string]$Message, [string]$Color = "White", [string]$Level = "INFO")
    
    $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] [DB-MIGRATION] $Message"
    Write-Host $logMessage -ForegroundColor $Color
    
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path "$LogDir\db-migration_$Timestamp.log" -Value $logMessage
}

function Invoke-SSHCommand {
    param([string]$Server, [string]$Command, [int]$MaxRetries = 3)
    
    if (-not $PlinkPath) {
        Write-ColorLog "ERROR: plink no encontrado" "Red" "ERROR"
        return $null
    }
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            $plinkArgs = @("-ssh", "-pw", $Password, "-batch", "$Username@$Server", $Command)
            $result = & $PlinkPath $plinkArgs 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                return $result
            } else {
                Write-ColorLog "Intento $i de $MaxRetries fallo para comando en $Server" "Yellow" "WARN"
                if ($i -lt $MaxRetries) { Start-Sleep -Seconds 5 }
            }
        }
        catch {
            $errorMsg = $_.Exception.Message
            Write-ColorLog "Excepcion en intento $i de $MaxRetries : $errorMsg" "Yellow" "WARN"
            if ($i -lt $MaxRetries) { Start-Sleep -Seconds 5 }
        }
    }
    
    Write-ColorLog "ERROR: Comando fallo despues de $MaxRetries intentos" "Red" "ERROR"
    return $null
}

function Test-Connectivity {
    Write-ColorLog "Verificando conectividad para migracion BD..." "Yellow"
    
    if (Test-Connection -ComputerName $DevServer -Count 1 -Quiet) {
        Write-ColorLog "Dev server conectividad: OK" "Green"
    } else {
        Write-ColorLog "Dev server conectividad: FALLO" "Red" "ERROR"
        return $false
    }
    
    if (Test-Connection -ComputerName $StageServer -Count 1 -Quiet) {
        Write-ColorLog "Stage server conectividad: OK" "Green"
    } else {
        Write-ColorLog "Stage server conectividad: FALLO" "Red" "ERROR"
        return $false
    }
    
    $testDev = Invoke-SSHCommand -Server $DevServer -Command "echo test"
    if ($testDev) {
        Write-ColorLog "SSH Dev: OK" "Green"
    } else {
        Write-ColorLog "SSH Dev: FALLO" "Red" "ERROR"
        return $false
    }
    
    $testStage = Invoke-SSHCommand -Server $StageServer -Command "echo test"
    if ($testStage) {
        Write-ColorLog "SSH Stage: OK" "Green"
    } else {
        Write-ColorLog "SSH Stage: FALLO" "Red" "ERROR"
        return $false
    }
    
    return $true
}

function Test-WordPress {
    param([string]$Server, [string]$Path, [string]$EnvName)
    
    Write-ColorLog "Verificando WordPress BD en $EnvName..." "Yellow"
    
    $wpCommand = "cd $Path; wp core is-installed"
    $plinkArgs = @("-ssh", "-pw", $Password, "-batch", "$Username@$Server", $wpCommand)
    $result = & $PlinkPath $plinkArgs 2>&1
    $wpInstalled = ($LASTEXITCODE -eq 0)
    
    if ($wpInstalled) {
        Write-ColorLog "$EnvName WordPress: WordPress instalado correctamente" "Green"
        
        $versionCommand = "cd $Path; wp core version"
        $wpVersion = Invoke-SSHCommand -Server $Server -Command $versionCommand
        if ($wpVersion) {
            Write-ColorLog "$EnvName WordPress: Version $($wpVersion.Trim())" "Green"
        }
        
        $dbCommand = "cd $Path; wp db check"
        $plinkArgs = @("-ssh", "-pw", $Password, "-batch", "$Username@$Server", $dbCommand)
        $dbResult = & $PlinkPath $plinkArgs 2>&1
        $dbHealthy = ($LASTEXITCODE -eq 0)
        
        if ($dbHealthy) {
            Write-ColorLog "$EnvName WordPress BD: Base de datos saludable" "Green"
            return $true
        } else {
            Write-ColorLog "$EnvName WordPress BD: Base de datos tiene problemas" "Red" "ERROR"
            return $false
        }
    } else {
        Write-ColorLog "$EnvName WordPress BD: WordPress no instalado o no accesible" "Red" "ERROR"
        return $false
    }
}

function Show-AvailableBackups {
    Write-ColorLog "=== BACKUPS BD DISPONIBLES ===" "Cyan"
    Write-ColorLog "Servidor: Stage ($StageServer)" "White"
    Write-ColorLog ""
    
    $safetyBackups = Invoke-SSHCommand -Server $StageServer -Command "ls -lt /tmp/stage_safety_db_backup_*.sql"
    
    if ($safetyBackups -and $safetyBackups.Trim()) {
        Write-ColorLog "SAFETY BACKUPS (para rollback):" "Green"
        $safetyBackups -split "`n" | ForEach-Object {
            if ($_.Trim()) {
                $parts = $_ -split '\s+'
                if ($parts.Length -ge 9) {
                    $fileName = $parts[-1]
                    $fileSize = $parts[4]
                    $fileDate = "$($parts[5]) $($parts[6]) $($parts[7])"
                    
                    if ($fileName -match 'stage_safety_db_backup_(.+)\.sql') {
                        $migrationId = $matches[1]
                        Write-ColorLog "  $fileName" "White"
                        Write-ColorLog "     Migration ID: $migrationId" "Yellow"
                        Write-ColorLog "     Tamaño: $fileSize | Fecha: $fileDate" "Gray"
                        Write-ColorLog "     Comando: .\migrate-database-clean.ps1 -Operation rollback -MigrationId $migrationId" "Cyan"
                        Write-ColorLog ""
                    }
                }
            }
        }
        
        Write-ColorLog "COMANDOS UTILES:" "Cyan"
        Write-ColorLog "  Rollback automatico: .\migrate-database-clean.ps1 -Operation rollback" "Yellow"
        Write-ColorLog "  Rollback especifico: .\migrate-database-clean.ps1 -Operation rollback -MigrationId [ID]" "Yellow"
        
    } else {
        Write-ColorLog "No se encontraron backups BD disponibles" "Yellow"
        Write-ColorLog "Para crear un backup manual:" "White"
        Write-ColorLog "  .\migrate-database-clean.ps1 -Operation backup" "Cyan"
    }
    
    $diskSpace = Invoke-SSHCommand -Server $StageServer -Command "df -h /tmp | tail -1"
    if ($diskSpace) {
        $spaceParts = $diskSpace -split '\s+'
        if ($spaceParts.Length -ge 4) {
            Write-ColorLog ""
            Write-ColorLog "ESPACIO EN DISCO (/tmp):" "Cyan"
            Write-ColorLog "  Total: $($spaceParts[1]) | Libre: $($spaceParts[3])" "White"
        }
    }
}

function Execute-DatabaseMigration {
    param([string]$MigrationId)
    
    Write-ColorLog "=== INICIANDO MIGRACION BD ===" "Cyan"
    Write-ColorLog "Migration ID: $MigrationId" "Cyan"
    
    if ($DryRun) {
        Write-ColorLog "DRY-RUN: Simulando migracion BD completa" "Magenta"
        return $true
    }
    
    # Paso 1: Backup Dev
    Write-ColorLog "Paso 1/4: Creando backup Development..." "Yellow"
    $backupCmd = "cd $DevPath; wp db export /tmp/dev_db_backup_${MigrationId}.sql"
    $result = Invoke-SSHCommand -Server $DevServer -Command $backupCmd
    if (-not $result) { return $false }
    
    # Paso 2: Safety backup Stage  
    Write-ColorLog "Paso 2/4: Creando safety backup Stage..." "Yellow"
    $safetyCmd = "cd $StagePath; wp db export /tmp/stage_safety_db_backup_${MigrationId}.sql"
    $result = Invoke-SSHCommand -Server $StageServer -Command $safetyCmd
    if (-not $result) { return $false }
    
    # Paso 3: Transferir via Windows
    Write-ColorLog "Paso 3/4: Transfiriendo backup Dev -> Stage..." "Yellow"
    $tempFile = "$env:TEMP\dev_db_backup_${MigrationId}.sql"
    
    $PscpPath = $PlinkPath -replace "plink", "pscp"
    if ($PlinkPath -eq "plink") { $PscpPath = "pscp" }
    
    # Descargar
    $downloadArgs = @("-pw", $Password, "-batch", "admwb@${DevServer}:/tmp/dev_db_backup_${MigrationId}.sql", $tempFile)
    $downloadResult = & $PscpPath $downloadArgs 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }
    
    # Subir
    $uploadArgs = @("-pw", $Password, "-batch", $tempFile, "admwb@${StageServer}:/tmp/")
    $uploadResult = & $PscpPath $uploadArgs 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }
    
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    
    # Paso 4: Importar
    Write-ColorLog "Paso 4/4: Importando BD en Stage..." "Yellow"
    $importCmd = "cd $StagePath; wp db import /tmp/dev_db_backup_${MigrationId}.sql"
    $result = Invoke-SSHCommand -Server $StageServer -Command $importCmd
    if (-not $result) { return $false }
    
    # Actualizar URLs
    Write-ColorLog "Actualizando URLs WordPress..." "Yellow"
    $searchCmd = "cd $StagePath; wp search-replace 'dev.website.local' 'web3stg.ciriontechnologies.com' --skip-columns=guid"
    $result = Invoke-SSHCommand -Server $StageServer -Command $searchCmd
    if (-not $result) { return $false }
    
    $homeCmd = "cd $StagePath; wp option update home 'https://web3stg.ciriontechnologies.com'"
    $siteCmd = "cd $StagePath; wp option update siteurl 'https://web3stg.ciriontechnologies.com'"
    Invoke-SSHCommand -Server $StageServer -Command $homeCmd | Out-Null
    Invoke-SSHCommand -Server $StageServer -Command $siteCmd | Out-Null
    
    Write-ColorLog "SUCCESS: Migracion BD completada" "Green"
    return $true
}

function Execute-DatabaseRollback {
    param([string]$MigrationId)
    
    Write-ColorLog "=== ROLLBACK BD ===" "Red"
    
    if (-not $MigrationId) {
        Write-ColorLog "Buscando backup mas reciente..." "Yellow"
        $recentBackup = Invoke-SSHCommand -Server $StageServer -Command "ls -t /tmp/stage_safety_db_backup_*.sql | head -1"
        
        if ($recentBackup -and $recentBackup.Trim()) {
            $backupFile = Split-Path $recentBackup.Trim() -Leaf
            if ($backupFile -match 'stage_safety_db_backup_(.+)\.sql') {
                $MigrationId = $matches[1]
                Write-ColorLog "BACKUP MAS RECIENTE: $backupFile" "Green"
                Write-ColorLog "Migration ID: $MigrationId" "Green"
                
                $confirmation = Read-Host "Continuar con rollback automatico? (S/N)"
                if ($confirmation -notlike "S*" -and $confirmation -notlike "Y*") {
                    Write-ColorLog "Rollback cancelado" "Yellow"
                    return $false
                }
            } else {
                Write-ColorLog "ERROR: No se pudo extraer Migration ID" "Red" "ERROR"
                return $false
            }
        } else {
            Write-ColorLog "ERROR: No se encontraron backups disponibles" "Red" "ERROR"
            return $false
        }
    }
    
    if ($DryRun) {
        Write-ColorLog "DRY-RUN: Simularia rollback BD con ID: $MigrationId" "Magenta"
        return $true
    }
    
    $backupFile = "stage_safety_db_backup_$MigrationId.sql"
    $testCmd = "test -f /tmp/$backupFile"
    Invoke-SSHCommand -Server $StageServer -Command $testCmd | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        Write-ColorLog "ERROR: Backup no encontrado: $backupFile" "Red" "ERROR"
        return $false
    }
    
    Write-ColorLog "Restaurando BD Stage desde backup..." "Yellow"
    $restoreCmd = "cd $StagePath; wp db import /tmp/$backupFile"
    $result = Invoke-SSHCommand -Server $StageServer -Command $restoreCmd
    
    if ($result) {
        Write-ColorLog "SUCCESS: BD restaurada exitosamente" "Green"
        return $true
    } else {
        Write-ColorLog "ERROR: Fallo restaurando BD" "Red" "ERROR"
        return $false
    }
}

# MAIN EXECUTION
Write-ColorLog "============================================" "White"
Write-ColorLog "WordPress Database Migration Manager - CLEAN" "Cyan"
Write-ColorLog "============================================" "White"
Write-ColorLog "Operacion: $Operation" "White"
if ($DryRun) { Write-ColorLog "Modo: DRY-RUN" "Magenta" }
Write-ColorLog "Migration ID: $Timestamp" "White"
Write-ColorLog "============================================" "White"

if (-not $PlinkPath) {
    Write-ColorLog "ERROR: plink no encontrado" "Red" "ERROR"
    exit 1
}

if ($Operation -ne "status" -and $Operation -ne "list-backups") {
    if (-not (Test-Connectivity)) {
        Write-ColorLog "ERROR: Fallo conectividad" "Red" "ERROR"
        exit 1
    }
}

switch ($Operation) {
    "status" {
        Test-Connectivity | Out-Null
        Write-ColorLog "Sistema operativo" "Green"
        exit 0
    }
    
    "list-backups" {
        Show-AvailableBackups
        exit 0
    }
    
    "pre-check" {
        $devCheck = Test-WordPress -Server $DevServer -Path $DevPath -EnvName "Development"
        $stageCheck = Test-WordPress -Server $StageServer -Path $StagePath -EnvName "Stage"
        
        if ($devCheck -and $stageCheck) {
            Write-ColorLog "SUCCESS: Pre-check BD exitoso" "Green"
            exit 0
        } else {
            Write-ColorLog "ERROR: Pre-check BD fallo" "Red" "ERROR"
            exit 1
        }
    }
    
    "migrate" {
        $migrationId = if ($MigrationId) { $MigrationId } else { $Timestamp }
        if (Execute-DatabaseMigration -MigrationId $migrationId) {
            Write-ColorLog "SUCCESS: Migracion BD exitosa" "Green"
            exit 0
        } else {
            exit 1
        }
    }
    
    "rollback" {
        if (Execute-DatabaseRollback -MigrationId $MigrationId) {
            Write-ColorLog "SUCCESS: Rollback BD exitoso" "Green"
            exit 0
        } else {
            exit 1
        }
    }
    
    "verify" {
        if (Test-WordPress -Server $StageServer -Path $StagePath -EnvName "Stage") {
            Write-ColorLog "SUCCESS: Verificacion BD exitosa" "Green"
            exit 0
        } else {
            exit 1
        }
    }
}

Write-ColorLog "Operacion completada" "Green"