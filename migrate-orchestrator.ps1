param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("pre-check", "migrate", "rollback", "status", "verify", "migrate-db-only", "migrate-uploads-only")]
    [string]$Operation,
    
    [Parameter(Mandatory=$false)]
    [string]$MigrationId,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("rsync", "zip", "robocopy")]
    [string]$UploadsMethod = "rsync",
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipDatabase,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipUploads,
    
    [Parameter(Mandatory=$false)]
    [switch]$Parallel
)

# ============================================================================
# CONFIGURACIÓN
# ============================================================================

$ScriptDir = "C:\Scripts\WordPress"
$LogDir = "$ScriptDir\Logs"
$DatabaseScript = "$ScriptDir\migrate-database.ps1"
$UploadsScript = "$ScriptDir\migrate-uploads.ps1"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Generar Migration ID único si no se proporciona
if (-not $MigrationId) {
    $MigrationId = $Timestamp
}

# ============================================================================
# FUNCIONES BÁSICAS
# ============================================================================

function Write-ColorLog {
    param([string]$Message, [string]$Color = "White", [string]$Level = "INFO")
    
    $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] [ORCHESTRATOR] $Message"
    Write-Host $logMessage -ForegroundColor $Color
    
    # Log a archivo
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path "$LogDir\orchestrator_$Timestamp.log" -Value $logMessage
}

function Test-ScriptAvailability {
    Write-ColorLog "Verificando disponibilidad de scripts..." "Yellow"
    
    $scriptsOK = $true
    
    if (-not (Test-Path $DatabaseScript)) {
        Write-ColorLog "ERROR: Script BD no encontrado: $DatabaseScript" "Red" "ERROR"
        $scriptsOK = $false
    } else {
        Write-ColorLog "✓ Script BD encontrado" "Green"
    }
    
    if (-not (Test-Path $UploadsScript)) {
        Write-ColorLog "ERROR: Script uploads no encontrado: $UploadsScript" "Red" "ERROR"
        $scriptsOK = $false
    } else {
        Write-ColorLog "✓ Script uploads encontrado" "Green"
    }
    
    return $scriptsOK
}

function Invoke-ComponentScript {
    param(
        [string]$ScriptPath,
        [string]$Operation,
        [string]$MigrationId,
        [hashtable]$AdditionalParams = @{},
        [string]$ComponentName
    )
    
    Write-ColorLog "Ejecutando $ComponentName`: $Operation" "Cyan"
    
    # Construir argumentos
    $scriptArgs = @(
        "-Operation", $Operation,
        "-MigrationId", $MigrationId
    )
    
    # Agregar parámetros adicionales
    foreach ($key in $AdditionalParams.Keys) {
        $scriptArgs += "-$key"
        if ($AdditionalParams[$key] -ne $true) {  # Para switches, no agregar valor
            $scriptArgs += $AdditionalParams[$key]
        }
    }
    
    if ($DryRun) {
        $scriptArgs += "-DryRun"
    }
    
    Write-ColorLog "Comando: $ScriptPath $($scriptArgs -join ' ')" "Gray"
    
    try {
        $result = & PowerShell -File $ScriptPath @scriptArgs
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            Write-ColorLog "✓ $ComponentName exitoso" "Green"
            return $true
        } else {
            Write-ColorLog "✗ $ComponentName falló (exit code: $exitCode)" "Red" "ERROR"
            return $false
        }
    }
    catch {
        Write-ColorLog "✗ $ComponentName excepción: $($_.Exception.Message)" "Red" "ERROR"
        return $false
    }
}

# ============================================================================
# FUNCIONES DE OPERACIONES COORDINADAS
# ============================================================================

function Execute-PreCheck {
    Write-ColorLog "=== PRE-CHECK COORDINADO ===" "Cyan"
    
    $preCheckSuccess = $true
    
    if (-not $SkipDatabase) {
        Write-ColorLog "Pre-check Base de Datos..." "Yellow"
        if (-not (Invoke-ComponentScript -ScriptPath $DatabaseScript -Operation "pre-check" -MigrationId $MigrationId -ComponentName "BD Pre-Check")) {
            $preCheckSuccess = $false
        }
    }
    
    if (-not $SkipUploads) {
        Write-ColorLog "Pre-check Uploads..." "Yellow"
        $uploadsParams = @{ "Method" = $UploadsMethod }
        if (-not (Invoke-ComponentScript -ScriptPath $UploadsScript -Operation "pre-check" -MigrationId $MigrationId -AdditionalParams $uploadsParams -ComponentName "Uploads Pre-Check")) {
            $preCheckSuccess = $false
        }
    }
    
    if ($preCheckSuccess) {
        Write-ColorLog "SUCCESS: Pre-check coordinado exitoso" "Green"
        return $true
    } else {
        Write-ColorLog "ERROR: Pre-check coordinado falló" "Red" "ERROR"
        return $false
    }
}

function Execute-CoordinatedMigration {
    Write-ColorLog "=== MIGRACIÓN COORDINADA ===" "Cyan"
    Write-ColorLog "Migration ID: $MigrationId" "Cyan"
    Write-ColorLog "Uploads Method: $UploadsMethod" "Cyan"
    Write-ColorLog "Paralelo: $Parallel" "Cyan"
    Write-ColorLog "Skip BD: $SkipDatabase | Skip Uploads: $SkipUploads" "Cyan"
    
    $migrationStartTime = Get-Date
    $migrationSuccess = $true
    
    if ($DryRun) {
        Write-ColorLog "DRY-RUN: Simulando migración completa coordinada" "Magenta"
        return $true
    }
    
    if ($Parallel -and -not $SkipDatabase -and -not $SkipUploads) {
        # Ejecución paralela
        Write-ColorLog "Ejecutando migración en paralelo..." "Yellow"
        
        # Iniciar trabajos paralelos
        $dbJob = Start-Job -ScriptBlock {
            param($ScriptPath, $MigrationId, $DryRun)
            $args = @("-Operation", "migrate", "-MigrationId", $MigrationId)
            if ($DryRun) { $args += "-DryRun" }
            & PowerShell -File $ScriptPath @args
        } -ArgumentList $DatabaseScript, $MigrationId, $DryRun
        
        $uploadsJob = Start-Job -ScriptBlock {
            param($ScriptPath, $MigrationId, $Method, $DryRun)
            $args = @("-Operation", "migrate", "-MigrationId", $MigrationId, "-Method", $Method)
            if ($DryRun) { $args += "-DryRun" }
            & PowerShell -File $ScriptPath @args
        } -ArgumentList $UploadsScript, $MigrationId, $UploadsMethod, $DryRun
        
        Write-ColorLog "Esperando finalización de trabajos paralelos..." "Yellow"
        
        # Esperar trabajos
        $dbResult = Wait-Job $dbJob | Receive-Job
        $uploadsResult = Wait-Job $uploadsJob | Receive-Job
        
        # Verificar resultados
        if ($dbJob.State -eq "Completed" -and $uploadsJob.State -eq "Completed") {
            Write-ColorLog "✓ Migraciones paralelas completadas" "Green"
        } else {
            Write-ColorLog "✗ Error en migraciones paralelas" "Red" "ERROR"
            $migrationSuccess = $false
        }
        
        # Limpiar trabajos
        Remove-Job $dbJob, $uploadsJob -Force
        
    } else {
        # Ejecución secuencial
        Write-ColorLog "Ejecutando migración secuencial..." "Yellow"
        
        # Paso 1: Migrar Base de Datos
        if (-not $SkipDatabase) {
            Write-ColorLog "Paso 1/2: Migrando Base de Datos..." "Yellow"
            if (-not (Invoke-ComponentScript -ScriptPath $DatabaseScript -Operation "migrate" -MigrationId $MigrationId -ComponentName "BD Migration")) {
                Write-ColorLog "ERROR: Migración BD falló - ABORTANDO" "Red" "ERROR"
                return $false
            }
        }
        
        # Paso 2: Migrar Uploads
        if (-not $SkipUploads) {
            Write-ColorLog "Paso 2/2: Migrando Uploads..." "Yellow"
            $uploadsParams = @{ "Method" = $UploadsMethod }
            if (-not (Invoke-ComponentScript -ScriptPath $UploadsScript -Operation "migrate" -MigrationId $MigrationId -AdditionalParams $uploadsParams -ComponentName "Uploads Migration")) {
                Write-ColorLog "ERROR: Migración uploads falló" "Red" "ERROR"
                $migrationSuccess = $false
            }
        }
    }
    
    $migrationEndTime = Get-Date
    $migrationDuration = ($migrationEndTime - $migrationStartTime).TotalSeconds
    
    if ($migrationSuccess) {
        Write-ColorLog "SUCCESS: Migración coordinada exitosa en ${migrationDuration}s" "Green"
        return $true
    } else {
        Write-ColorLog "ERROR: Migración coordinada falló después de ${migrationDuration}s" "Red" "ERROR"
        return $false
    }
}

function Execute-CoordinatedRollback {
    if (-not $MigrationId) {
        Write-ColorLog "ERROR: Migration ID requerido para rollback coordinado" "Red" "ERROR"
        return $false
    }
    
    Write-ColorLog "=== ROLLBACK COORDINADO ===" "Red"
    Write-ColorLog "Migration ID: $MigrationId" "Yellow"
    
    if ($DryRun) {
        Write-ColorLog "DRY-RUN: Simularía rollback completo coordinado" "Magenta"
        return $true
    }
    
    $rollbackSuccess = $true
    
    # Rollback en orden inverso: primero uploads, luego BD
    if (-not $SkipUploads) {
        Write-ColorLog "Rollback Uploads..." "Yellow"
        $uploadsParams = @{ "Method" = $UploadsMethod }
        if (-not (Invoke-ComponentScript -ScriptPath $UploadsScript -Operation "rollback" -MigrationId $MigrationId -AdditionalParams $uploadsParams -ComponentName "Uploads Rollback")) {
            Write-ColorLog "ERROR: Rollback uploads falló" "Red" "ERROR"
            $rollbackSuccess = $false
        }
    }
    
    if (-not $SkipDatabase) {
        Write-ColorLog "Rollback Base de Datos..." "Yellow"
        if (-not (Invoke-ComponentScript -ScriptPath $DatabaseScript -Operation "rollback" -MigrationId $MigrationId -ComponentName "BD Rollback")) {
            Write-ColorLog "ERROR: Rollback BD falló" "Red" "ERROR"
            $rollbackSuccess = $false
        }
    }
    
    if ($rollbackSuccess) {
        Write-ColorLog "SUCCESS: Rollback coordinado exitoso" "Green"
        return $true
    } else {
        Write-ColorLog "ERROR: Rollback coordinado incompleto" "Red" "ERROR"
        return $false
    }
}

function Execute-CoordinatedVerification {
    Write-ColorLog "=== VERIFICACIÓN COORDINADA ===" "Cyan"
    
    $verificationSuccess = $true
    
    if (-not $SkipDatabase) {
        Write-ColorLog "Verificación Base de Datos..." "Yellow"
        if (-not (Invoke-ComponentScript -ScriptPath $DatabaseScript -Operation "verify" -MigrationId $MigrationId -ComponentName "BD Verification")) {
            $verificationSuccess = $false
        }
    }
    
    if (-not $SkipUploads) {
        Write-ColorLog "Verificación Uploads..." "Yellow"
        $uploadsParams = @{ "Method" = $UploadsMethod }
        if (-not (Invoke-ComponentScript -ScriptPath $UploadsScript -Operation "verify" -MigrationId $MigrationId -AdditionalParams $uploadsParams -ComponentName "Uploads Verification")) {
            $verificationSuccess = $false
        }
    }
    
    if ($verificationSuccess) {
        Write-ColorLog "SUCCESS: Verificación coordinada exitosa" "Green"
        return $true
    } else {
        Write-ColorLog "ERROR: Verificación coordinada falló" "Red" "ERROR"
        return $false
    }
}

function Show-CoordinatedStatus {
    Write-ColorLog "=== STATUS COORDINADO ===" "Cyan"
    
    Write-ColorLog "Status Base de Datos:" "Yellow"
    Invoke-ComponentScript -ScriptPath $DatabaseScript -Operation "status" -MigrationId $MigrationId -ComponentName "BD Status" | Out-Null
    
    Write-ColorLog "`nStatus Uploads:" "Yellow"
    $uploadsParams = @{ "Method" = $UploadsMethod }
    Invoke-ComponentScript -ScriptPath $UploadsScript -Operation "status" -MigrationId $MigrationId -AdditionalParams $uploadsParams -ComponentName "Uploads Status" | Out-Null
    
    # Información del orquestador
    Write-ColorLog "`n=== CONFIGURACIÓN ORQUESTADOR ===" "Cyan"
    Write-ColorLog "Scripts disponibles:" "White"
    Write-ColorLog "  BD: $DatabaseScript" "Gray"
    Write-ColorLog "  Uploads: $UploadsScript" "Gray"
    Write-ColorLog "Método uploads por defecto: $UploadsMethod" "White"
    Write-ColorLog "Log directory: $LogDir" "White"
    Write-ColorLog "Migration ID actual: $MigrationId" "White"
}

# ============================================================================
# FUNCIONES DE CONTINGENCIA
# ============================================================================

function Execute-EmergencyRecovery {
    param([string]$MigrationId)
    
    Write-ColorLog "=== RECUPERACIÓN DE EMERGENCIA ===" "Red"
    Write-ColorLog "Migration ID: $MigrationId" "Yellow"
    
    if (-not $MigrationId) {
        Write-ColorLog "ERROR: Migration ID requerido para recuperación" "Red" "ERROR"
        return $false
    }
    
    Write-ColorLog "Intentando recuperación automática..." "Yellow"
    
    # Intentar rollback coordinado
    if (Execute-CoordinatedRollback) {
        Write-ColorLog "✓ Recuperación de emergencia exitosa via rollback" "Green"
        return $true
    } else {
        Write-ColorLog "✗ Recuperación de emergencia falló" "Red" "ERROR"
        Write-ColorLog "INTERVENCIÓN MANUAL REQUERIDA" "Red" "ERROR"
        Write-ColorLog "Contactar administrador de sistema" "Red" "ERROR"
        return $false
    }
}

function Generate-MigrationReport {
    param([string]$Status, [int]$Duration, [hashtable]$Details = @{})
    
    Write-ColorLog "Generando reporte de migración coordinada..." "Cyan"
    
    $reportFile = "$LogDir\migration_report_$MigrationId.json"
    
    $report = @{
        migration_id = $MigrationId
        timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        operation = $Operation
        status = $Status
        duration_seconds = $Duration
        uploads_method = $UploadsMethod
        dry_run = $DryRun.IsPresent
        parallel_execution = $Parallel.IsPresent
        skip_database = $SkipDatabase.IsPresent
        skip_uploads = $SkipUploads.IsPresent
        scripts = @{
            database = $DatabaseScript
            uploads = $UploadsScript
            orchestrator = $MyInvocation.MyCommand.Path
        }
        logs = @{
            orchestrator = "$LogDir\orchestrator_$Timestamp.log"
            database = "$LogDir\db-migration_$Timestamp.log"
            uploads = "$LogDir\uploads-migration_$Timestamp.log"
        }
        details = $Details
    }
    
    $report | ConvertTo-Json -Depth 3 | Out-File -FilePath $reportFile -Encoding UTF8
    Write-ColorLog "Reporte guardado: $reportFile" "Green"
    
    return $reportFile
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-ColorLog "============================================" "White"
Write-ColorLog "WordPress Migration Orchestrator" "Cyan"
Write-ColorLog "============================================" "White"
Write-ColorLog "Operación: $Operation" "White"
Write-ColorLog "Migration ID: $MigrationId" "White"
Write-ColorLog "Uploads Method: $UploadsMethod" "White"
if ($DryRun) { Write-ColorLog "Modo: DRY-RUN (simulación)" "Magenta" }
if ($Parallel) { Write-ColorLog "Modo: PARALELO" "Magenta" }
if ($SkipDatabase) { Write-ColorLog "SKIP: Base de Datos" "Yellow" }
if ($SkipUploads) { Write-ColorLog "SKIP: Uploads" "Yellow" }
Write-ColorLog "Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "White"
Write-ColorLog "============================================" "White"

# Verificar scripts disponibles
if (-not (Test-ScriptAvailability)) {
    Write-ColorLog "ERROR: Scripts no disponibles" "Red" "ERROR"
    exit 1
}

$startTime = Get-Date
$operationSuccess = $false

# Ejecutar operación principal
try {
    switch ($Operation) {
        "status" {
            Show-CoordinatedStatus
            $operationSuccess = $true
        }
        
        "pre-check" {
            $operationSuccess = Execute-PreCheck
        }
        
        "migrate" {
            # Pre-check antes de migración
            if (Execute-PreCheck) {
                $operationSuccess = Execute-CoordinatedMigration
                
                # Verificación post-migración automática
                if ($operationSuccess) {
                    Write-ColorLog "Ejecutando verificación post-migración..." "Cyan"
                    Execute-CoordinatedVerification | Out-Null
                }
            } else {
                Write-ColorLog "ERROR: Pre-check falló - ABORTANDO migración" "Red" "ERROR"
                $operationSuccess = $false
            }
        }
        
        "migrate-db-only" {
            $SkipUploads = $true
            Write-ColorLog "Migración solo BD activada" "Yellow"
            if (Execute-PreCheck) {
                $operationSuccess = Execute-CoordinatedMigration
            } else {
                Write-ColorLog "ERROR: Pre-check BD falló" "Red" "ERROR"
                $operationSuccess = $false
            }
        }
        
        "migrate-uploads-only" {
            $SkipDatabase = $true
            Write-ColorLog "Migración solo uploads activada" "Yellow"
            if (Execute-PreCheck) {
                $operationSuccess = Execute-CoordinatedMigration
            } else {
                Write-ColorLog "ERROR: Pre-check uploads falló" "Red" "ERROR"
                $operationSuccess = $false
            }
        }
        
        "rollback" {
            $operationSuccess = Execute-CoordinatedRollback
        }
        
        "verify" {
            $operationSuccess = Execute-CoordinatedVerification
        }
        
        default {
            Write-ColorLog "ERROR: Operación no válida: $Operation" "Red" "ERROR"
            $operationSuccess = $false
        }
    }
}
catch {
    Write-ColorLog "ERROR CRÍTICO: $($_.Exception.Message)" "Red" "ERROR"
    
    # Intentar recuperación de emergencia si fue una migración
    if ($Operation -eq "migrate" -and $MigrationId) {
        Write-ColorLog "Iniciando recuperación de emergencia..." "Red"
        Execute-EmergencyRecovery -MigrationId $MigrationId | Out-Null
    }
    
    $operationSuccess = $false
}

# Generar reporte final
$endTime = Get-Date
$totalDuration = ($endTime - $startTime).TotalSeconds

$reportDetails = @{
    start_time = $startTime.ToString('yyyy-MM-dd HH:mm:ss')
    end_time = $endTime.ToString('yyyy-MM-dd HH:mm:ss')
    total_duration = $totalDuration
}

$reportFile = Generate-MigrationReport -Status $(if($operationSuccess) {"SUCCESS"} else {"FAILED"}) -Duration $totalDuration -Details $reportDetails

# Resultado final
if ($operationSuccess) {
    Write-ColorLog "============================================" "Green"
    Write-ColorLog "OPERACIÓN COORDINADA EXITOSA" "Green"
    Write-ColorLog "============================================" "Green"
    Write-ColorLog "Operación: $Operation" "Green"
    Write-ColorLog "Migration ID: $MigrationId" "Green"
    Write-ColorLog "Duración total: ${totalDuration}s" "Green"
    Write-ColorLog "Reporte: $reportFile" "Green"
    
    if ($Operation -eq "migrate") {
        Write-ColorLog "" "Green"
        Write-ColorLog "Para rollback completo:" "Yellow"
        Write-ColorLog "  .\migrate-orchestrator.ps1 -Operation rollback -MigrationId $MigrationId" "Gray"
    }
    
    Write-ColorLog "============================================" "Green"
    exit 0
} else {
    Write-ColorLog "============================================" "Red"
    Write-ColorLog "OPERACIÓN COORDINADA FALLÓ" "Red"
    Write-ColorLog "============================================" "Red"
    Write-ColorLog "Operación: $Operation" "Red"
    Write-ColorLog "Migration ID: $MigrationId" "Red"
    Write-ColorLog "Duración: ${totalDuration}s" "Red"
    Write-ColorLog "Reporte: $reportFile" "Red"
    Write-ColorLog "Logs: $LogDir" "Red"
    
    if ($Operation -eq "migrate" -and $MigrationId) {
        Write-ColorLog "" "Red"
        Write-ColorLog "Para intentar rollback:" "Yellow"
        Write-ColorLog "  .\migrate-orchestrator.ps1 -Operation rollback -MigrationId $MigrationId" "Gray"
    }
    
    Write-ColorLog "============================================" "Red"
    exit 1
}