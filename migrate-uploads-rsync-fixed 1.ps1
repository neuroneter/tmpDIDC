param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("pre-check", "backup", "migrate", "rollback", "status", "verify", "list-backups")]
    [string]$Operation,
    
    [Parameter(Mandatory=$false)]
    [string]$MigrationId,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

# CONFIGURACION (IDENTICA A migrate-database.ps1)
$DevServer = "172.16.4.4"
$StageServer = "172.16.5.4"
$Username = "admwb"
$Password = "Cirion#617"
$DevPath = "/var/www/html/debweb/wp-content/uploads"
$StagePath = "/var/www/html/webcirion/wp-content/uploads"
$LogDir = "C:\Scripts\WordPress\Logs"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# CONFIGURACION ESPECIFICA UPLOADS RSYNC
$MaxBackups = 5
$RetentionDays = 7
$BackupPath = "/tmp/stage_uploads_backup"

# NUEVO: Configuración para transferencias grandes
$RsyncTimeout = 300  # 5 minutos de timeout para rsync
$RsyncMaxRetries = 3  # Máximo de reintentos para rsync
$RsyncChunkSize = "10M"  # Tamaño de bloque para transferencias grandes

# Buscar plink (IDENTICO)
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

# FUNCIONES BASICAS (ADAPTADAS PARA UPLOADS RSYNC)
function Write-ColorLog {
    param([string]$Message, [string]$Color = "White", [string]$Level = "INFO")
    
    # Component tag para RSYNC
    $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] [UPLOADS-RSYNC] $Message"
    Write-Host $logMessage -ForegroundColor $Color
    
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }
    # Filename para RSYNC
    Add-Content -Path "$LogDir\uploads-rsync_$Timestamp.log" -Value $logMessage
}

function Invoke-SSHCommand {
    param(
        [string]$Server, 
        [string]$Command, 
        [int]$MaxRetries = 3,
        [switch]$IsRsyncCommand = $false  # NUEVO: Indicador para comandos rsync
    )
    
    if (-not $PlinkPath) {
        Write-ColorLog "ERROR: plink no encontrado" "Red" "ERROR"
        return $null
    }
    
    # Ajustar timeouts específicos para rsync
    $retryDelay = 5
    $totalTimeout = 30  # 30 segundos por intento normal
    if ($IsRsyncCommand) {
        $retryDelay = 15  # Más tiempo entre reintentos para rsync
        $totalTimeout = 600  # 10 minutos para operaciones rsync
    }
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            $plinkArgs = @("-ssh", "-pw", $Password, "-batch", "$Username@$Server", $Command)
            
            # Iniciar el comando con temporizador
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $PlinkPath $plinkArgs 2>&1
            $stopwatch.Stop()
            
            # Verificar si excedió el timeout
            if ($stopwatch.Elapsed.TotalSeconds -gt $totalTimeout -and $LASTEXITCODE -ne 0) {
                Write-ColorLog "ERROR: Comando excedió el timeout de $totalTimeout segundos" "Red" "ERROR"
                return $null
            }
            
            if ($LASTEXITCODE -eq 0) {
                return $result
            } else {
                Write-ColorLog "Intento $i de $MaxRetries fallo para comando en $Server" "Yellow" "WARN"
                if ($i -lt $MaxRetries) { Start-Sleep -Seconds $retryDelay }
            }
        }
        catch {
            $errorMsg = $_.Exception.Message
            Write-ColorLog "Excepcion en intento $i de $MaxRetries : $errorMsg" "Yellow" "WARN"
            if ($i -lt $MaxRetries) { Start-Sleep -Seconds $retryDelay }
        }
    }
    
    Write-ColorLog "ERROR: Comando fallo despues de $MaxRetries intentos" "Red" "ERROR"
    return $null
}

# NUEVO: Función especializada para rsync con reintentos inteligentes
function Invoke-RsyncWithRetry {
    param(
        [string]$Server,
        [string]$RsyncCommand,
        [int]$MaxRetries = $RsyncMaxRetries
    )
    
    Write-ColorLog "Ejecutando rsync con hasta $MaxRetries reintentos..." "Yellow"
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-ColorLog "Intento rsync #$i de $MaxRetries..." "Cyan"
        
        $result = Invoke-SSHCommand -Server $Server -Command $RsyncCommand -IsRsyncCommand
        
        # Verificar si fue exitoso (código 0) o si fue una interrupción (código 20)
        if ($LASTEXITCODE -eq 0) {
            Write-ColorLog "RSYNC completado exitosamente" "Green"
            return $true
        }
        elseif ($LASTEXITCODE -eq 20) {
            Write-ColorLog "ERROR: Problema de red durante rsync (código 20). Reintentando..." "Yellow"
        }
        else {
            Write-ColorLog "ERROR rsync (código $LASTEXITCODE). Reintentando..." "Yellow"
        }
        
        if ($i -lt $MaxRetries) {
            Write-ColorLog "Esperando 30 segundos antes del próximo intento..." "Yellow"
            Start-Sleep -Seconds 30
        }
    }
    
    Write-ColorLog "ERROR: Rsync falló después de $MaxRetries intentos" "Red" "ERROR"
    return $false
}

function Test-Connectivity {
    Write-ColorLog "Verificando conectividad para migracion uploads RSYNC..." "Yellow"
    
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

# FUNCIONES ESPECIFICAS RSYNC (CORREGIDAS PARA RSYNC REMOTO)
function Test-RsyncPrerequisites {
    Write-ColorLog "Verificando prerequisitos RSYNC REMOTO..." "Yellow"
    
    # Verificar RSYNC disponible en ambos servidores
    $devRsync = Invoke-SSHCommand -Server $DevServer -Command "which rsync"
    $stageRsync = Invoke-SSHCommand -Server $StageServer -Command "which rsync"
    
    if (-not $devRsync -or -not $stageRsync) {
        Write-ColorLog "ERROR: RSYNC no disponible en algún servidor" "Red" "ERROR"
        Write-ColorLog "Dev RSYNC: $devRsync" "Red" "ERROR"
        Write-ColorLog "Stage RSYNC: $stageRsync" "Red" "ERROR"
        return $false
    }
    
    Write-ColorLog "RSYNC encontrado - Dev: $devRsync, Stage: $stageRsync" "Green"
    
    # Verificar directorio uploads Dev existe
    $devUploadsExists = Invoke-SSHCommand -Server $DevServer -Command "test -d $DevPath && echo EXISTS"
    if ($devUploadsExists -notlike "*EXISTS*") {
        Write-ColorLog "ERROR: Directorio uploads Dev no existe: $DevPath" "Red" "ERROR"
        return $false
    }
    
    # Verificar/crear directorio uploads Stage
    $stageUploadsExists = Invoke-SSHCommand -Server $StageServer -Command "test -d $StagePath && echo EXISTS"
    if ($stageUploadsExists -notlike "*EXISTS*") {
        Write-ColorLog "WARNING: Directorio uploads Stage no existe, creando..." "Yellow"
        $createResult = Invoke-SSHCommand -Server $StageServer -Command "mkdir -p $StagePath"
        if (-not $createResult -and $LASTEXITCODE -ne 0) {
            Write-ColorLog "ERROR: No se pudo crear directorio uploads Stage" "Red" "ERROR"
            return $false
        }
        Write-ColorLog "Directorio Stage uploads creado exitosamente" "Green"
    }
    
    # Verificar permisos de lectura Dev
    $devReadTest = Invoke-SSHCommand -Server $DevServer -Command "ls $DevPath > /dev/null 2>&1 && echo OK"
    if ($devReadTest -notlike "*OK*") {
        Write-ColorLog "ERROR: No se puede leer directorio uploads Dev" "Red" "ERROR"
        return $false
    }
    
    # Verificar permisos de escritura Stage
    $stageWriteTest = Invoke-SSHCommand -Server $StageServer -Command "touch $StagePath/.test_rsync && rm $StagePath/.test_rsync && echo OK"
    if ($stageWriteTest -notlike "*OK*") {
        Write-ColorLog "ERROR: Problemas con permisos de escritura en uploads Stage" "Red" "ERROR"
        return $false
    }
    
    Write-ColorLog "Permisos verificados: OK" "Green"
    
    # Analizar contenido actual
    $devFileCount = Invoke-SSHCommand -Server $DevServer -Command "find $DevPath -type f | wc -l"
    $devSizeRaw = Invoke-SSHCommand -Server $DevServer -Command "du -sh $DevPath"
    $stageFileCount = Invoke-SSHCommand -Server $StageServer -Command "find $StagePath -type f | wc -l"
    
    if (-not $devFileCount) { $devFileCount = "0" }
    if (-not $stageFileCount) { $stageFileCount = "0" }
    
    $devSize = "desconocido"
    if ($devSizeRaw) {
        $devSizeParts = $devSizeRaw -split '\s+'
        if ($devSizeParts.Length -ge 1) {
            $devSize = $devSizeParts[0]
        }
    }
    
    Write-ColorLog "Dev uploads: $devFileCount archivos ($devSize)" "White"
    Write-ColorLog "Stage uploads: $stageFileCount archivos" "White"
    
    if ([int]$devFileCount -eq 0) {
        Write-ColorLog "WARNING: No hay archivos en Dev uploads para migrar" "Yellow" "WARN"
        Write-ColorLog "La migración creará estructura vacía en Stage" "Yellow"
    }
    
    # Test conectividad SSH desde Stage a Dev para RSYNC
    Write-ColorLog "Verificando conectividad SSH Stage->Dev para RSYNC..." "Yellow"
    $sshTest = Invoke-SSHCommand -Server $StageServer -Command "ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=no $Username@$DevServer 'echo SSH_TEST' 2>/dev/null || echo 'SSH_REQUIRES_PASSWORD'"
    
    if ($sshTest -like "*SSH_REQUIRES_PASSWORD*") {
        Write-ColorLog "INFO: SSH requiere password - usaremos sshpass" "Yellow"
        
        # Verificar si sshpass está disponible
        $sshpassCheck = Invoke-SSHCommand -Server $StageServer -Command "which sshpass"
        if (-not $sshpassCheck) {
            Write-ColorLog "ERROR: sshpass no disponible en Stage para RSYNC remoto" "Red" "ERROR"
            Write-ColorLog "SOLUCION: Instalar sshpass en Stage: apt-get install sshpass" "Yellow"
            return $false
        }
        Write-ColorLog "sshpass disponible: $sshpassCheck" "Green"
    } elseif ($sshTest -like "*SSH_TEST*") {
        Write-ColorLog "SSH sin password configurado: OK" "Green"
    } else {
        Write-ColorLog "WARNING: Conectividad SSH Stage->Dev no confirmada" "Yellow" "WARN"
    }
    
    Write-ColorLog "Pre-check RSYNC REMOTO completado exitosamente" "Green"
    return $true
}

function Show-AvailableRsyncBackups {
    Write-ColorLog "=== BACKUPS UPLOADS RSYNC DISPONIBLES ===" "Cyan"
    Write-ColorLog "Servidor: Stage ($StageServer)" "White"
    Write-ColorLog ""
    
    $backups = Invoke-SSHCommand -Server $StageServer -Command "ls -lt $BackupPath* 2>/dev/null"
    
    if ($backups -and $backups.Trim()) {
        Write-ColorLog "BACKUPS DISPONIBLES (para rollback):" "Green"
        $backups -split "`n" | ForEach-Object {
            if ($_.Trim()) {
                Write-ColorLog "  $_" "White"
            }
        }
        
        Write-ColorLog ""
        Write-ColorLog "COMANDOS UTILES:" "Cyan"
        Write-ColorLog "  Rollback automatico: .\migrate-uploads-rsync-fixed.ps1 -Operation rollback" "Yellow"
        Write-ColorLog "  Rollback especifico: .\migrate-uploads-rsync-fixed.ps1 -Operation rollback -MigrationId [ID]" "Yellow"
        
    } else {
        Write-ColorLog "No se encontraron backups uploads disponibles" "Yellow"
        Write-ColorLog "Para crear un backup manual:" "White"
        Write-ColorLog "  .\migrate-uploads-rsync-fixed.ps1 -Operation backup" "Cyan"
    }
    
    $diskSpace = Invoke-SSHCommand -Server $StageServer -Command "df -h $StagePath | tail -1"
    if ($diskSpace) {
        Write-ColorLog ""
        Write-ColorLog "ESPACIO EN DISCO:" "Cyan"
        Write-ColorLog "  $diskSpace" "White"
    }
}

function Create-StageUploadsBackupRsync {
    param([string]$MigrationId)
    
    Write-ColorLog "Creando backup safety uploads Stage con RSYNC..." "Yellow"
    
    $backupDir = "$BackupPath`_$MigrationId"
    
    # Verificar si hay contenido en Stage
    $stageFileCount = Invoke-SSHCommand -Server $StageServer -Command "find $StagePath -type f | wc -l"
    if (-not $stageFileCount) { $stageFileCount = "0" }
    
    Write-ColorLog "Archivos a respaldar en Stage: $stageFileCount" "White"
    
    if ([int]$stageFileCount -eq 0) {
        Write-ColorLog "INFO: No hay archivos en Stage uploads, creando backup vacío" "Yellow"
        # Crear directorio backup vacío para mantener consistencia
        $emptyBackupResult = Invoke-SSHCommand -Server $StageServer -Command "mkdir -p $backupDir && touch $backupDir/.empty_backup"
    } else {
        # Crear backup real con RSYNC local en Stage
        $backupCmd = "rsync -av $StagePath/ $backupDir/"
        $result = Invoke-SSHCommand -Server $StageServer -Command $backupCmd
        
        if (-not $result) {
            Write-ColorLog "ERROR: Fallo creando backup safety uploads Stage" "Red" "ERROR"
            return $false
        }
    }
    
    # Verificar backup creado
    $backupInfo = Invoke-SSHCommand -Server $StageServer -Command "ls -la $backupDir | head -5"
    if ($backupInfo) {
        Write-ColorLog "Backup safety creado en: $backupDir" "Green"
        Write-ColorLog "Contenido backup: $backupInfo" "Gray"
    } else {
        Write-ColorLog "ERROR: No se pudo verificar backup safety creado" "Red" "ERROR"
        return $false
    }
    
    # NUEVO: Verificación adicional del backup
    $backupFileCount = Invoke-SSHCommand -Server $StageServer -Command "find $backupDir -type f | wc -l"
    if ($backupFileCount -ne $stageFileCount) {
        Write-ColorLog "WARNING: Conteo de archivos en backup ($backupFileCount) no coincide con Stage ($stageFileCount)" "Yellow"
        Write-ColorLog "Puede haber problemas con el backup" "Yellow"
    } else {
        Write-ColorLog "VERIFICACION: Backup contiene el mismo número de archivos que Stage ($backupFileCount)" "Green"
    }
    
    return $true
}

function Execute-UploadsRsyncMigration {
    param([string]$MigrationId)
    
    Write-ColorLog "=== INICIANDO MIGRACION UPLOADS RSYNC REMOTO ===" "Cyan"
    Write-ColorLog "Migration ID: $MigrationId" "Cyan"
    Write-ColorLog "MODO: Solo copiar archivos nuevos de DEV a STG (sin borrar nada)" "Yellow"
    Write-ColorLog "CONFIG: Timeout rsync: $RsyncTimeout segundos, Reintentos máximos: $RsyncMaxRetries" "Yellow"
    
    if ($DryRun) {
        Write-ColorLog "DRY-RUN: Simulando migracion uploads RSYNC REMOTO completa" "Magenta"
        
        # Comando RSYNC remoto con dry-run (SOLO NUEVOS ARCHIVOS)
        $sshOptions = "-o StrictHostKeyChecking=no -o ServerAliveInterval=60 -o ServerAliveCountMax=3"
        $dryRunCmd = "sshpass -p '$Password' rsync -avz --timeout=$RsyncTimeout --ignore-existing --dry-run --itemize-changes -e 'ssh $sshOptions' $Username@$DevServer`:$DevPath/ $StagePath/"
        $dryRunResult = Invoke-SSHCommand -Server $StageServer -Command $dryRunCmd -IsRsyncCommand
        
        if ($dryRunResult) {
            Write-ColorLog "DRY-RUN: Cambios que se aplicarían (SOLO ARCHIVOS NUEVOS):" "Magenta"
            $dryRunResult -split "`n" | Select-Object -First 10 | ForEach-Object {
                Write-ColorLog "  $_" "Gray"
            }
        } else {
            Write-ColorLog "DRY-RUN: No se detectaron cambios o error en comando" "Yellow"
        }
        return $true
    }
    
    # Paso 1: Crear backup safety Stage
    Write-ColorLog "Paso 1/4: Creando backup safety uploads Stage..." "Yellow"
    if (-not (Create-StageUploadsBackupRsync -MigrationId $MigrationId)) {
        return $false
    }
    
    # NUEVO: Verificar que el backup se creó correctamente ANTES de continuar
    $backupDir = "$BackupPath`_$MigrationId"
    $backupCheck = Invoke-SSHCommand -Server $StageServer -Command "test -d $backupDir && echo EXISTS"
    if ($backupCheck -notlike "*EXISTS*") {
        Write-ColorLog "ERROR CRITICO: Backup no se creó correctamente antes de la migración" "Red" "ERROR"
        Write-ColorLog "NO SE PUEDE CONTINUAR - Los datos en Stage están en riesgo" "Red" "ERROR"
        return $false
    }
    
    # Paso 2: Pre-migración - Mostrar qué va a cambiar
    Write-ColorLog "Paso 2/4: Analizando cambios a aplicar con RSYNC REMOTO..." "Yellow"
    $sshOptions = "-o StrictHostKeyChecking=no -o ServerAliveInterval=60 -o ServerAliveCountMax=3"
    $changesCmd = "sshpass -p '$Password' rsync -avz --timeout=$RsyncTimeout --ignore-existing --dry-run --itemize-changes -e 'ssh $sshOptions' $Username@$DevServer`:$DevPath/ $StagePath/"
    $changes = Invoke-SSHCommand -Server $StageServer -Command $changesCmd -IsRsyncCommand
    
    if ($changes) {
        $changesCount = ($changes -split "`n").Count
        Write-ColorLog "Archivos nuevos detectados: $changesCount items" "White"
    } else {
        Write-ColorLog "No se detectaron archivos nuevos para copiar" "Yellow"
    }
    
    # Paso 3: Migración real con RSYNC REMOTO (SOLO ARCHIVOS NUEVOS)
    Write-ColorLog "Paso 3/4: === EJECUTANDO RSYNC REMOTO MIGRATION ===" "Red"
    Write-ColorLog "Comando: sshpass rsync -avz Dev->Stage uploads (SOLO ARCHIVOS NUEVOS)" "Gray"
    Write-ColorLog "OPCIONES: --timeout=$RsyncTimeout -P (permitir reanudar) --ignore-existing" "Gray"
    
    # NUEVO: Opciones SSH mejoradas para mantener la conexión
    $sshOptions = "-o StrictHostKeyChecking=no -o ServerAliveInterval=60 -o ServerAliveCountMax=3"
    
    # CORREGIDO: Uso de --ignore-existing para solo copiar archivos nuevos
    $rsyncCmd = "sshpass -p '$Password' rsync -avz --timeout=$RsyncTimeout -P --progress " +
                "--block-size=$RsyncChunkSize " +
                "--ignore-existing " +  # SOLO COPIA ARCHIVOS QUE NO EXISTEN EN DESTINO
                "-e 'ssh $sshOptions' " +
                "$Username@$DevServer`:$DevPath/ $StagePath/"
    
    # Ejecutar con sistema de reintentos especializado
    if (-not (Invoke-RsyncWithRetry -Server $StageServer -RsyncCommand $rsyncCmd)) {
        Write-ColorLog "ERROR CRÍTICO: Fallo en RSYNC REMOTO migration después de múltiples intentos" "Red" "ERROR"
        Write-ColorLog "EJECUTANDO ROLLBACK AUTOMÁTICO..." "Red"
        Execute-UploadsRsyncRollback -MigrationId $MigrationId
        return $false
    }
    
    Write-ColorLog "RSYNC REMOTO completado exitosamente" "Green"
    
    # Paso 4: Verificación final
    Write-ColorLog "Paso 4/4: Verificación final migración..." "Yellow"
    
    # NUEVO: Verificación más detallada
    $devFilesAfter = Invoke-SSHCommand -Server $DevServer -Command "find $DevPath -type f | wc -l"
    $stageFilesBefore = Invoke-SSHCommand -Server $StageServer -Command "find $backupDir -type f | wc -l"
    $stageFilesAfter = Invoke-SSHCommand -Server $StageServer -Command "find $StagePath -type f | wc -l"
    
    Write-ColorLog "Verificación de conteos:" "Cyan"
    Write-ColorLog "  Dev uploads: $devFilesAfter archivos" "White"
    Write-ColorLog "  Stage uploads (antes): $stageFilesBefore archivos" "White"
    Write-ColorLog "  Stage uploads (después): $stageFilesAfter archivos" "White"
    
    # Calcular cuántos archivos nuevos se añadieron
    $newFilesAdded = [int]$stageFilesAfter - [int]$stageFilesBefore
    
    Write-ColorLog "  Archivos nuevos añadidos: $newFilesAdded" "White"
    
    if ($newFilesAdded -ge 0) {
        Write-ColorLog "SUCCESS: Migración completada - Se añadieron $newFilesAdded archivos nuevos" "Green"
        Write-ColorLog "NINGUN ARCHIVO EXISTENTE EN STAGE FUE MODIFICADO O ELIMINADO" "Green"
    } else {
        Write-ColorLog "WARNING: No se añadieron archivos nuevos (posible problema)" "Yellow"
    }
    
    # Limpiar backups muy antiguos
    Remove-OldRsyncBackups
    
    return $true
}

function Execute-UploadsRsyncRollback {
    param([string]$MigrationId)
    
    Write-ColorLog "=== ROLLBACK UPLOADS RSYNC ===" "Red"
    
    if (-not $MigrationId) {
        Write-ColorLog "Buscando backup mas reciente..." "Yellow"
        $recentBackup = Invoke-SSHCommand -Server $StageServer -Command "ls -td $BackupPath* 2>/dev/null | head -1"
        
        if ($recentBackup -and $recentBackup.Trim()) {
            $backupDir = $recentBackup.Trim()
            if ($backupDir -match "$BackupPath`_(.+)") {
                $MigrationId = $matches[1]
                Write-ColorLog "BACKUP MAS RECIENTE: $backupDir" "Green"
                Write-ColorLog "Migration ID: $MigrationId" "Green"
                # Sin confirmación (igual que en BD)
            } else {
                Write-ColorLog "ERROR: No se pudo extraer Migration ID" "Red" "ERROR"
                return $false
            }
        } else {
            Write-ColorLog "ERROR: No se encontraron backups uploads disponibles" "Red" "ERROR"
            return $false
        }
    }
    
    if ($DryRun) {
        Write-ColorLog "DRY-RUN: Simularia rollback uploads RSYNC con ID: $MigrationId" "Magenta"
        return $true
    }
    
    $backupDir = "$BackupPath`_$MigrationId"
    $testCmd = "test -d $backupDir"
    Invoke-SSHCommand -Server $StageServer -Command $testCmd | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        Write-ColorLog "ERROR: Backup uploads no encontrado: $backupDir" "Red" "ERROR"
        return $false
    }
    
    Write-ColorLog "Restaurando uploads Stage desde backup con RSYNC..." "Yellow"
    
    # Eliminar contenido actual Stage
    Invoke-SSHCommand -Server $StageServer -Command "rm -rf $StagePath/*"
    
    # Restaurar desde backup con RSYNC local
    $restoreCmd = "rsync -av $backupDir/ $StagePath/"
    $result = Invoke-SSHCommand -Server $StageServer -Command $restoreCmd
    
    if ($result -or $LASTEXITCODE -eq 0) {
        $restoredFiles = Invoke-SSHCommand -Server $StageServer -Command "find $StagePath -type f | wc -l"
        Write-ColorLog "SUCCESS: Uploads restaurados exitosamente con RSYNC - $restoredFiles archivos" "Green"
        return $true
    } else {
        Write-ColorLog "ERROR: Fallo restaurando uploads con RSYNC" "Red" "ERROR"
        return $false
    }
}

function Remove-OldRsyncBackups {
    Write-ColorLog "Aplicando retención backups RSYNC..." "Yellow"
    
    # Limpiar por tiempo (más de 7 días)
    $oldBackups = Invoke-SSHCommand -Server $StageServer -Command "find /tmp -name 'stage_uploads_backup_*' -type d -mtime +$RetentionDays 2>/dev/null"
    
    # También limpiar por cantidad (más de 5)
    $excessBackups = Invoke-SSHCommand -Server $StageServer -Command "ls -td $BackupPath* 2>/dev/null | tail -n +$((MaxBackups + 1))"
    
    if ($oldBackups) {
        $oldBackups -split "`n" | ForEach-Object {
            if ($_.Trim()) {
                $backupPath = $_.Trim()
                Invoke-SSHCommand -Server $StageServer -Command "rm -rf '$backupPath'"
                Write-ColorLog "Backup eliminado (antiguo): $(Split-Path $backupPath -Leaf)" "Gray"
            }
        }
    }
    
    if ($excessBackups) {
        $excessBackups -split "`n" | ForEach-Object {
            if ($_.Trim()) {
                $backupPath = $_.Trim()
                Invoke-SSHCommand -Server $StageServer -Command "rm -rf '$backupPath'"
                Write-ColorLog "Backup eliminado (exceso): $(Split-Path $backupPath -Leaf)" "Gray"
            }
        }
    }
}

# MAIN EXECUTION (IDENTICA ESTRUCTURA)
Write-ColorLog "============================================" "White"
Write-ColorLog "WordPress Uploads Migration Manager - RSYNC REMOTO" "Cyan"
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
        Write-ColorLog "Sistema uploads RSYNC REMOTO operativo" "Green"
        exit 0
    }
    
    "list-backups" {
        Show-AvailableRsyncBackups
        exit 0
    }
    
    "pre-check" {
        if (Test-RsyncPrerequisites) {
            Write-ColorLog "SUCCESS: Pre-check uploads RSYNC REMOTO exitoso" "Green"
            exit 0
        } else {
            Write-ColorLog "ERROR: Pre-check uploads RSYNC REMOTO fallo" "Red" "ERROR"
            exit 1
        }
    }
    
    "backup" {
        $migrationId = if ($MigrationId) { $MigrationId } else { $Timestamp }
        if (Create-StageUploadsBackupRsync -MigrationId $migrationId) {
            Write-ColorLog "SUCCESS: Backup uploads RSYNC exitoso" "Green"
            exit 0
        } else {
            exit 1
        }
    }
    
    "migrate" {
        $migrationId = if ($MigrationId) { $MigrationId } else { $Timestamp }
        if (Execute-UploadsRsyncMigration -MigrationId $migrationId) {
            Write-ColorLog "SUCCESS: Migracion uploads RSYNC REMOTO exitosa" "Green"
            exit 0
        } else {
            exit 1
        }
    }
    
    "rollback" {
        if (Execute-UploadsRsyncRollback -MigrationId $MigrationId) {
            Write-ColorLog "SUCCESS: Rollback uploads RSYNC exitoso" "Green"
            exit 0
        } else {
            exit 1
        }
    }
    
    "verify" {
        $devFiles = Invoke-SSHCommand -Server $DevServer -Command "find $DevPath -type f | wc -l"
        $stageFiles = Invoke-SSHCommand -Server $StageServer -Command "find $StagePath -type f | wc -l"
        
        Write-ColorLog "Verificacion uploads RSYNC:" "Cyan"
        Write-ColorLog "  Dev: $devFiles archivos" "White"
        Write-ColorLog "  Stage: $stageFiles archivos" "White"
        
        if ($devFiles -eq $stageFiles) {
            Write-ColorLog "SUCCESS: Verificacion uploads RSYNC exitosa - Conteos coinciden" "Green"
            exit 0
        } else {
            Write-ColorLog "WARNING: Conteos uploads diferentes" "Yellow" "WARN"
            exit 1
        }
    }
}

Write-ColorLog "Operacion uploads RSYNC REMOTO completada" "Green"