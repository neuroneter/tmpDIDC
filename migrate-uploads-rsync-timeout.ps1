param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("pre-check", "backup", "migrate", "rollback", "status", "verify", "check-job")]
    [string]$Operation,
    
    [Parameter(Mandatory=$false)]
    [string]$JobId,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [switch]$PreserveExisting  # No borrar archivos existentes en destino
)

# CONFIGURACION
$DevServer = "172.16.4.4"
$StageServer = "172.16.5.4"
$Username = "admwb"
$Password = "Cirion#617"
$DevPath = "/var/www/html/debweb/wp-content/uploads"
$StagePath = "/var/www/html/webcirion/wp-content/uploads"
$BackupBasePath = "/var/www/html/uploads_backups"
$JobsPath = "/var/www/html/migration_jobs"
$LogDir = "C:\Scripts\WordPress\Logs"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Configuración de timeouts y keep-alive
$SSHKeepAlive = "-o ServerAliveInterval=30 -o ServerAliveCountMax=120"  # Mantiene vivo por 60 min
$PlinkKeepAlive = "-keepalive 30"  # Para plink

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
    
    $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] [UPLOADS-ASYNC] $Message"
    Write-Host $logMessage -ForegroundColor $Color
    
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path "$LogDir\uploads-async_$Timestamp.log" -Value $logMessage
}

function Invoke-SSHCommand {
    param(
        [string]$Server, 
        [string]$Command,
        [switch]$NoTimeout  # Para comandos rápidos
    )
    
    if (-not $PlinkPath) {
        Write-ColorLog "ERROR: plink no encontrado" "Red" "ERROR"
        return $null
    }
    
    try {
        # Ajustar argumentos según si necesitamos keep-alive
        if ($NoTimeout) {
            $plinkArgs = @("-ssh", "-pw", $Password, "-batch", "$Username@$Server", $Command)
        } else {
            $plinkArgs = @("-ssh", "-pw", $Password, "-batch", $PlinkKeepAlive, "$Username@$Server", $Command)
        }
        
        $result = & $PlinkPath $plinkArgs 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            return $result
        } else {
            Write-ColorLog "Error ejecutando comando en $Server" "Red" "ERROR"
            return $null
        }
    }
    catch {
        Write-ColorLog "Excepcion: $($_.Exception.Message)" "Red" "ERROR"
        return $null
    }
}

# FUNCIONES PARA MANEJO DE JOBS ASINCRONOS
function Create-AsyncJob {
    param(
        [string]$JobType,
        [string]$JobCommand,
        [hashtable]$JobMetadata = @{}
    )
    
    $jobId = "$JobType`_$Timestamp"
    $jobFile = "$JobsPath/$jobId.job"
    $logFile = "$JobsPath/$jobId.log"
    $statusFile = "$JobsPath/$jobId.status"
    
    Write-ColorLog "Creando job asíncrono: $jobId" "Yellow"
    
    # Crear directorio de jobs si no existe
    Invoke-SSHCommand -Server $StageServer -Command "sudo mkdir -p $JobsPath" -NoTimeout
    
    # Crear script del job
    $jobScript = @"
#!/bin/bash
# Job: $jobId
# Type: $JobType
# Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

# Función para actualizar estado
update_status() {
    echo "\$1" | sudo tee $statusFile > /dev/null
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | sudo tee -a $logFile
}

# Función para progreso periódico (evita timeout)
report_progress() {
    while kill -0 \$1 2>/dev/null; do
        sleep 30
        if [ -f "$StagePath/.rsync_progress" ]; then
            progress=\$(tail -1 $StagePath/.rsync_progress 2>/dev/null || echo "En progreso...")
            update_status "RUNNING: \$progress"
        else
            update_status "RUNNING: Procesando..."
        fi
    done
}

# Inicio del job
update_status "STARTED"

# Ejecutar comando principal
(
    $JobCommand
) 2>&1 | sudo tee -a $logFile &

MAIN_PID=\$!

# Monitorear progreso en background
report_progress \$MAIN_PID &
PROGRESS_PID=\$!

# Esperar a que termine el comando principal
wait \$MAIN_PID
RESULT=\$?

# Terminar monitor de progreso
kill \$PROGRESS_PID 2>/dev/null

# Actualizar estado final
if [ \$RESULT -eq 0 ]; then
    update_status "COMPLETED"
else
    update_status "FAILED"
fi

# Guardar metadata
echo "Exit Code: \$RESULT" | sudo tee -a $logFile
"@

    # Guardar script en el servidor
    $escapedScript = $jobScript -replace '"', '\"' -replace '\$', '\$'
    Invoke-SSHCommand -Server $StageServer -Command "echo `"$escapedScript`" | sudo tee $jobFile > /dev/null" -NoTimeout
    Invoke-SSHCommand -Server $StageServer -Command "sudo chmod +x $jobFile" -NoTimeout
    
    # Ejecutar en background con nohup
    Write-ColorLog "Iniciando job en background..." "Yellow"
    Invoke-SSHCommand -Server $StageServer -Command "nohup sudo $jobFile > /dev/null 2>&1 &" -NoTimeout
    
    # Esperar un momento para confirmar que inició
    Start-Sleep -Seconds 2
    
    # Verificar que el job está corriendo
    $status = Invoke-SSHCommand -Server $StageServer -Command "cat $statusFile 2>/dev/null || echo 'NOT_FOUND'" -NoTimeout
    
    if ($status -like "*STARTED*" -or $status -like "*RUNNING*") {
        Write-ColorLog "Job iniciado exitosamente: $jobId" "Green"
        Write-ColorLog "Use -Operation check-job -JobId $jobId para verificar progreso" "Cyan"
        return $jobId
    } else {
        Write-ColorLog "ERROR: No se pudo iniciar el job" "Red" "ERROR"
        return $null
    }
}

function Check-AsyncJob {
    param([string]$JobId)
    
    if (-not $JobId) {
        # Listar jobs recientes
        Write-ColorLog "=== JOBS RECIENTES ===" "Cyan"
        $jobs = Invoke-SSHCommand -Server $StageServer -Command "ls -lt $JobsPath/*.status 2>/dev/null | head -10" -NoTimeout
        
        if ($jobs) {
            Write-ColorLog "Jobs disponibles:" "Yellow"
            $jobs -split "`n" | ForEach-Object {
                if ($_ -match "([^/]+)\.status") {
                    $jobName = $matches[1]
                    $status = Invoke-SSHCommand -Server $StageServer -Command "cat $JobsPath/$jobName.status 2>/dev/null | tail -1" -NoTimeout
                    Write-ColorLog "  $jobName : $status" "White"
                }
            }
        } else {
            Write-ColorLog "No se encontraron jobs" "Yellow"
        }
        return
    }
    
    # Verificar job específico
    $statusFile = "$JobsPath/$JobId.status"
    $logFile = "$JobsPath/$JobId.log"
    
    $status = Invoke-SSHCommand -Server $StageServer -Command "cat $statusFile 2>/dev/null || echo 'NOT_FOUND'" -NoTimeout
    
    if ($status -eq "NOT_FOUND") {
        Write-ColorLog "Job no encontrado: $JobId" "Red" "ERROR"
        return
    }
    
    Write-ColorLog "=== ESTADO DEL JOB: $JobId ===" "Cyan"
    Write-ColorLog "Estado: $status" "Yellow"
    
    if ($status -like "*RUNNING*") {
        # Mostrar progreso actual
        Write-ColorLog "El job está en progreso..." "Yellow"
        
        # Mostrar últimas líneas del log
        $tailLog = Invoke-SSHCommand -Server $StageServer -Command "sudo tail -20 $logFile 2>/dev/null" -NoTimeout
        if ($tailLog) {
            Write-ColorLog "`nÚltimas líneas del log:" "White"
            Write-ColorLog "$tailLog" "Gray"
        }
        
        # Intentar obtener progreso de rsync si está disponible
        $rsyncProgress = Invoke-SSHCommand -Server $StageServer -Command "tail -5 $StagePath/.rsync_progress 2>/dev/null" -NoTimeout
        if ($rsyncProgress) {
            Write-ColorLog "`nProgreso de rsync:" "White"
            Write-ColorLog "$rsyncProgress" "Gray"
        }
        
    } elseif ($status -like "*COMPLETED*") {
        Write-ColorLog "El job se completó exitosamente" "Green"
        
        # Mostrar resumen
        $summary = Invoke-SSHCommand -Server $StageServer -Command "grep -E 'transferred|total size' $logFile 2>/dev/null | tail -5" -NoTimeout
        if ($summary) {
            Write-ColorLog "`nResumen:" "White"
            Write-ColorLog "$summary" "Gray"
        }
        
    } elseif ($status -like "*FAILED*") {
        Write-ColorLog "El job falló" "Red" "ERROR"
        
        # Mostrar error
        $error = Invoke-SSHCommand -Server $StageServer -Command "sudo tail -20 $logFile 2>/dev/null" -NoTimeout
        if ($error) {
            Write-ColorLog "`nError:" "White"
            Write-ColorLog "$error" "Gray"
        }
    }
}

# FUNCIONES PRINCIPALES AJUSTADAS
function Test-Prerequisites {
    Write-ColorLog "=== PRE-CHECK CON ANTI-TIMEOUT ===" "Cyan"
    
    # 1. Verificar conectividad básica (rápido)
    Write-ColorLog "1. Verificando conectividad..." "Yellow"
    if (-not (Test-Connection -ComputerName $StageServer -Count 1 -Quiet)) {
        Write-ColorLog "ERROR: No hay conectividad con Stage" "Red" "ERROR"
        return $false
    }
    
    # 2. Test SSH con timeout corto
    $testSSH = Invoke-SSHCommand -Server $StageServer -Command "echo 'SSH OK'" -NoTimeout
    if ($testSSH -notlike "*SSH OK*") {
        Write-ColorLog "ERROR: No se puede conectar por SSH a Stage" "Red" "ERROR"
        return $false
    }
    Write-ColorLog "Conectividad SSH: OK" "Green"
    
    # 3. Verificar montajes
    Write-ColorLog "2. Verificando montajes Azure Files..." "Yellow"
    $stageMount = Invoke-SSHCommand -Server $StageServer -Command "df -h | grep $StagePath" -NoTimeout
    if ($stageMount) {
        Write-ColorLog "Stage Azure Files: OK" "Green"
    } else {
        Write-ColorLog "ERROR: Azure Files no montado en Stage" "Red" "ERROR"
        return $false
    }
    
    # 4. Test rápido Stage->Dev
    Write-ColorLog "3. Verificando acceso Stage->Dev..." "Yellow"
    $stageToDevTest = Invoke-SSHCommand -Server $StageServer -Command "timeout 5 ssh -o StrictHostKeyChecking=no $Username@$DevServer 'echo OK' 2>&1 || echo 'NEED_AUTH'" -NoTimeout
    
    if ($stageToDevTest -like "*NEED_AUTH*") {
        Write-ColorLog "Autenticación requerida (normal)" "Yellow"
    } else {
        Write-ColorLog "Conexión Stage->Dev: OK" "Green"
    }
    
    # 5. Espacio y archivos (comandos rápidos)
    Write-ColorLog "4. Analizando contenido..." "Yellow"
    $devInfo = Invoke-SSHCommand -Server $StageServer -Command "ssh $Username@$DevServer 'du -sh $DevPath 2>/dev/null; find $DevPath -type f 2>/dev/null | wc -l'" -NoTimeout
    $stageInfo = Invoke-SSHCommand -Server $StageServer -Command "df -h $StagePath | tail -1; find $StagePath -type f | wc -l" -NoTimeout
    
    Write-ColorLog "Info Dev: $devInfo" "White"
    Write-ColorLog "Info Stage: $stageInfo" "White"
    
    Write-ColorLog "PRE-CHECK COMPLETADO" "Green"
    return $true
}

function Create-Backup {
    param([switch]$Async)
    
    Write-ColorLog "=== CREANDO BACKUP ===" "Cyan"
    
    $backupName = "uploads_backup_$Timestamp"
    $backupPath = "$BackupBasePath/$backupName"
    
    if ($DryRun) {
        Write-ColorLog "DRY-RUN: Crearía backup en: $backupPath" "Magenta"
        return $backupPath
    }
    
    if ($Async) {
        # Crear backup asíncrono para evitar timeout
        $backupCmd = @"
sudo mkdir -p $BackupBasePath
sudo cp -r $StagePath $backupPath
sudo chown -R $Username:$Username $backupPath
echo "Backup size: \$(du -sh $backupPath | cut -f1)"
"@
        
        $jobId = Create-AsyncJob -JobType "backup" -JobCommand $backupCmd
        return $jobId
    } else {
        # Backup síncrono (para backups pequeños)
        Invoke-SSHCommand -Server $StageServer -Command "sudo mkdir -p $BackupBasePath" -NoTimeout
        Invoke-SSHCommand -Server $StageServer -Command "sudo cp -r $StagePath $backupPath"
        
        $backupSize = Invoke-SSHCommand -Server $StageServer -Command "du -sh $backupPath 2>/dev/null | cut -f1" -NoTimeout
        if ($backupSize) {
            Write-ColorLog "Backup creado: $backupSize" "Green"
            return $backupPath
        } else {
            Write-ColorLog "ERROR: No se pudo crear backup" "Red" "ERROR"
            return $null
        }
    }
}

function Execute-Migration {
    Write-ColorLog "=== EJECUTANDO MIGRACION ASINCRONA ===" "Cyan"
    
    # Determinar opciones de rsync según PreserveExisting
    $rsyncOptions = "-av --progress"
    if (-not $PreserveExisting) {
        $rsyncOptions += " --delete"
        Write-ColorLog "Modo: Sincronización completa (se eliminarán archivos no existentes en origen)" "Yellow"
    } else {
        Write-ColorLog "Modo: Preservar archivos existentes (no se eliminará nada)" "Green"
        $rsyncOptions += " --ignore-existing"  # No sobrescribir archivos existentes
    }
    
    if ($DryRun) {
        Write-ColorLog "DRY-RUN: Simulando migración..." "Magenta"
        $dryCmd = "sudo rsync $rsyncOptions --dry-run $Username@$DevServer`:$DevPath/ $StagePath/ 2>&1 | head -50"
        $dryResult = Invoke-SSHCommand -Server $StageServer -Command $dryCmd
        
        if ($dryResult) {
            Write-ColorLog "Cambios que se aplicarían:" "Magenta"
            Write-ColorLog "$dryResult" "Gray"
        }
        return $true
    }
    
    # Crear comando de migración para job asíncrono
    $migrationCmd = @"
# Crear backup primero
echo "Creando backup de seguridad..."
sudo mkdir -p $BackupBasePath
backup_name="uploads_backup_$Timestamp"
sudo cp -r $StagePath $BackupBasePath/\$backup_name
echo "Backup creado: \$backup_name"

# Ejecutar rsync con progreso
echo "Iniciando sincronización rsync..."
sudo rsync $rsyncOptions \
    --log-file=$JobsPath/rsync_$Timestamp.log \
    --info=progress2 \
    $Username@$DevServer:$DevPath/ $StagePath/ 2>&1 | \
    tee $StagePath/.rsync_progress

# Verificar resultado
RSYNC_RESULT=\${PIPESTATUS[0]}
echo "Rsync exit code: \$RSYNC_RESULT"

if [ \$RSYNC_RESULT -eq 0 ]; then
    echo "Ajustando permisos..."
    sudo chown -R www-data:www-data $StagePath
    sudo chmod -R 755 $StagePath
    
    # Limpiar archivo de progreso
    sudo rm -f $StagePath/.rsync_progress
    
    # Contar archivos
    file_count=\$(find $StagePath -type f | wc -l)
    size_total=\$(du -sh $StagePath | cut -f1)
    echo "Migración completada: \$file_count archivos, \$size_total total"
else
    echo "ERROR: Rsync falló con código \$RSYNC_RESULT"
    exit \$RSYNC_RESULT
fi
"@
    
    # Crear job asíncrono
    Write-ColorLog "Iniciando migración asíncrona..." "Yellow"
    Write-ColorLog "NOTA: Este proceso puede tomar varios minutos" "Yellow"
    
    $jobId = Create-AsyncJob -JobType "migration" -JobCommand $migrationCmd
    
    if ($jobId) {
        Write-ColorLog "" "White"
        Write-ColorLog "=== MIGRACION INICIADA ===" "Green"
        Write-ColorLog "Job ID: $jobId" "Cyan"
        Write-ColorLog "" "White"
        Write-ColorLog "Para verificar el progreso use:" "Yellow"
        Write-ColorLog "  .\$($MyInvocation.MyCommand.Name) -Operation check-job -JobId $jobId" "Cyan"
        Write-ColorLog "" "White"
        Write-ColorLog "El proceso continuará ejecutándose aunque cierre esta ventana" "Green"
        return $true
    } else {
        Write-ColorLog "ERROR: No se pudo iniciar la migración" "Red" "ERROR"
        return $false
    }
}

function Execute-Rollback {
    Write-ColorLog "=== EJECUTANDO ROLLBACK ===" "Red"
    
    # Buscar el backup más reciente
    $latestBackup = Invoke-SSHCommand -Server $StageServer -Command "ls -t $BackupBasePath/uploads_backup_* 2>/dev/null | head -1" -NoTimeout
    
    if (-not $latestBackup) {
        Write-ColorLog "ERROR: No se encontraron backups" "Red" "ERROR"
        return $false
    }
    
    Write-ColorLog "Backup encontrado: $latestBackup" "Yellow"
    
    if ($DryRun) {
        Write-ColorLog "DRY-RUN: Restauraría desde: $latestBackup" "Magenta"
        return $true
    }
    
    # Confirmar
    Write-Host ""
    Write-Host "ATENCION: Esto restaurará uploads desde el backup" -ForegroundColor Red
    Write-Host "Backup: $latestBackup" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "¿Continuar? (si/no)"
    
    if ($confirm -ne "si") {
        Write-ColorLog "Rollback cancelado" "Yellow"
        return $false
    }
    
    # Rollback asíncrono
    $rollbackCmd = @"
echo "Iniciando rollback desde: $latestBackup"

# Crear backup del estado actual antes de rollback
current_backup="$BackupBasePath/pre_rollback_$Timestamp"
echo "Guardando estado actual en: \$current_backup"
sudo cp -r $StagePath \$current_backup

# Limpiar directorio actual
echo "Limpiando directorio actual..."
sudo rm -rf $StagePath/*

# Restaurar desde backup
echo "Restaurando desde backup..."
sudo cp -r $latestBackup/* $StagePath/

# Ajustar permisos
echo "Ajustando permisos..."
sudo chown -R www-data:www-data $StagePath
sudo chmod -R 755 $StagePath

# Verificar
file_count=\$(find $StagePath -type f | wc -l)
echo "Rollback completado: \$file_count archivos restaurados"
"@
    
    $jobId = Create-AsyncJob -JobType "rollback" -JobCommand $rollbackCmd
    
    if ($jobId) {
        Write-ColorLog "Rollback iniciado: $jobId" "Yellow"
        Write-ColorLog "Verifique progreso con: -Operation check-job -JobId $jobId" "Cyan"
        return $true
    } else {
        return $false
    }
}

function Show-Status {
    Write-ColorLog "=== ESTADO ACTUAL ===" "Cyan"
    
    # Montajes
    Write-ColorLog "Azure Files:" "Yellow"
    $mount = Invoke-SSHCommand -Server $StageServer -Command "df -h | grep uploads" -NoTimeout
    Write-ColorLog "$mount" "White"
    
    # Contenido
    Write-ColorLog "`nContenido:" "Yellow"
    $stats = Invoke-SSHCommand -Server $StageServer -Command @"
echo "Dev Server:"
ssh $Username@$DevServer 'find $DevPath -type f 2>/dev/null | wc -l; du -sh $DevPath 2>/dev/null'
echo "Stage Server:"
find $StagePath -type f | wc -l; du -sh $StagePath
"@ -NoTimeout
    
    Write-ColorLog "$stats" "White"
    
    # Jobs recientes
    Write-ColorLog "`nJobs recientes:" "Yellow"
    Check-AsyncJob
    
    # Backups
    Write-ColorLog "`nBackups disponibles:" "Yellow"
    $backups = Invoke-SSHCommand -Server $StageServer -Command "ls -lah $BackupBasePath/ 2>/dev/null | tail -5" -NoTimeout
    Write-ColorLog "$backups" "Gray"
}

# MAIN EXECUTION
Write-ColorLog "============================================" "White"
Write-ColorLog "WordPress Uploads Migration - Async Mode" "Cyan"
Write-ColorLog "============================================" "White"
Write-ColorLog "Operación: $Operation" "White"
if ($DryRun) { Write-ColorLog "Modo: DRY-RUN" "Magenta" }
if ($PreserveExisting) { Write-ColorLog "Modo: PRESERVAR EXISTENTES" "Green" }
Write-ColorLog "Timestamp: $Timestamp" "White"
Write-ColorLog "============================================" "White"

if (-not $PlinkPath) {
    Write-ColorLog "ERROR: plink no encontrado" "Red" "ERROR"
    exit 1
}

switch ($Operation) {
    "status" {
        Show-Status
        exit 0
    }
    
    "pre-check" {
        if (Test-Prerequisites) {
            Write-ColorLog "Pre-check exitoso" "Green"
            exit 0
        } else {
            Write-ColorLog "Pre-check falló" "Red" "ERROR"
            exit 1
        }
    }
    
    "backup" {
        $result = Create-Backup -Async
        if ($result) {
            Write-ColorLog "Backup iniciado: $result" "Green"
            exit 0
        } else {
            exit 1
        }
    }
    
    "migrate" {
        if (Execute-Migration) {
            exit 0
        } else {
            exit 1
        }
    }
    
    "rollback" {
        if (Execute-Rollback) {
            exit 0
        } else {
            exit 1
        }
    }
    
    "verify" {
        # Verificación rápida
        $counts = Invoke-SSHCommand -Server $StageServer -Command @"
echo -n "Dev: "
ssh $Username@$DevServer 'find $DevPath -type f 2>/dev/null | wc -l'
echo -n "Stage: "
find $StagePath -type f | wc -l
"@ -NoTimeout
        
        Write-ColorLog "Verificación de archivos:" "Cyan"
        Write-ColorLog "$counts" "White"
        exit 0
    }
    
    "check-job" {
        Check-AsyncJob -JobId $JobId
        exit 0
    }
}

Write-ColorLog "Operación completada" "Green"
