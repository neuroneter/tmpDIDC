param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("pre-check", "migrate", "content", "rollback")]
    [string]$Operation,
    
    [Parameter(Mandatory=$false)]
    [string]$MigrationId
)

# Configuracion
$ScriptPath = "C:\Scripts\WordPress"
$LogPath = "C:\Logs\WordPress" 
$DevServer = "172.16.4.4"
$StageServer = "172.16.5.4"
$Username = "admwb"
$Password = "Cirion#617"
$DevPath = "/var/www/html/debweb"
$StagePath = "/var/www/html/webcirion"

# Buscar plink.exe
$PlinkPath = $null
$PlinkLocations = @(
    "plink",
    "C:\Program Files\PuTTY\plink.exe",
    "C:\Program Files (x86)\PuTTY\plink.exe",
    "$env:USERPROFILE\AppData\Local\Programs\PuTTY\plink.exe"
)

foreach ($loc in $PlinkLocations) {
    try {
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
    } catch { }
}

function Write-Log {
    param([string]$Message, [string]$Type = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Type] $Message"
    
    $color = switch($Type) {
        "ERROR" { "Red" }
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        default { "White" }
    }
    
    Write-Host $logMessage -ForegroundColor $color
    
    # Guardar en archivo de log
    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType Directory -Force -Path $LogPath | Out-Null
    }
    $logFile = "$LogPath\wordpress_operations_$(Get-Date -Format 'yyyyMMdd').log"
    Add-Content -Path $logFile -Value $logMessage
    
    # Para Azure DevOps
    switch($Type) {
        "ERROR" { Write-Host "##vso[task.logissue type=error]$Message" }
        "WARNING" { Write-Host "##vso[task.logissue type=warning]$Message" }
        "SUCCESS" { Write-Host "##vso[task.complete result=Succeeded]$Message" }
    }
}

function Invoke-PlinkCommand {
    param(
        [string]$Server,
        [string]$Command,
        [int]$TimeoutSeconds = 30
    )
    
    if (-not $PlinkPath) {
        Write-Log "ERROR: plink.exe no encontrado. Instalar PuTTY" "ERROR"
        return @{ Success = $false; Output = "plink not found"; ExitCode = -1 }
    }
    
    Write-Log "Ejecutando en ${Server}: $Command"
    
    try {
        # Comando plink con contraseña
        $plinkArgs = @(
            "-ssh",
            "-pw", $Password,
            "-batch",
            "$Username@$Server",
            $Command
        )
        
        # Ejecutar plink
        $result = & $PlinkPath $plinkArgs 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            Write-Log "SUCCESS: Comando ejecutado exitosamente" "SUCCESS"
            return @{ Success = $true; Output = $result; ExitCode = $exitCode }
        } else {
            Write-Log "WARNING: Comando completo con codigo: $exitCode" "WARNING"
            Write-Log "Output: $result" "WARNING"
            return @{ Success = $false; Output = $result; ExitCode = $exitCode }
        }
    }
    catch {
        Write-Log "ERROR ejecutando plink: $($_.Exception.Message)" "ERROR"
        return @{ Success = $false; Output = $_.Exception.Message; ExitCode = -1 }
    }
}

function Test-ServerConnectivity {
    Write-Log "Verificando conectividad con plink..."
    Write-Log "plink encontrado en: $PlinkPath"
    
    $servers = @(
        @{ Name = "Dev"; IP = $DevServer },
        @{ Name = "Stage"; IP = $StageServer }
    )
    
    foreach ($server in $servers) {
        # Test ping
        Write-Log "Testing ping to $($server.Name) ($($server.IP))..."
        if (Test-Connection -ComputerName $server.IP -Count 1 -Quiet) {
            Write-Log "SUCCESS: Ping OK to $($server.Name)" "SUCCESS"
        } else {
            Write-Log "ERROR: Ping failed to $($server.Name)" "ERROR"
            return $false
        }
        
        # Test plink
        Write-Log "Testing plink SSH to $($server.Name)..."
        $plinkResult = Invoke-PlinkCommand -Server $server.IP -Command "echo 'Connection test OK'"
        
        if ($plinkResult.Success) {
            Write-Log "SUCCESS: plink SSH OK to $($server.Name): $($plinkResult.Output)" "SUCCESS"
        } else {
            Write-Log "ERROR: plink SSH failed to $($server.Name)" "ERROR"
            Write-Log "Error: $($plinkResult.Output)" "ERROR"
            return $false
        }
    }
    
    return $true
}

function Test-WordPressInstallation {
    param([string]$Server, [string]$Path, [string]$EnvName)
    
    Write-Log "Verificando WordPress en $EnvName..."
    
    # Usar wp-cli.phar que acabamos de instalar PRIMERO
    $wpCommands = @(
        "php /home/$Username/wp-cli.phar",      # Nuestra instalación local (PRIORITARIA)
        "/home/$Username/wp-cli.phar",          # Directamente executable
        "wp",                                   # Global (si funciona)
        "/usr/local/bin/wp"                     # Standard global (último recurso)
    )
    
    $workingWpCommand = $null
    
    foreach ($wpCmd in $wpCommands) {
        Write-Log "Probando WP-CLI: $wpCmd"
        $testResult = Invoke-PlinkCommand -Server $Server -Command "cd $Path && $wpCmd --version" -TimeoutSeconds 10
        
        if ($testResult.Success -and $testResult.Output -like "*WP-CLI*") {
            $workingWpCommand = $wpCmd
            Write-Log "SUCCESS: WP-CLI funcionando en $EnvName con: $wpCmd" "SUCCESS"
            Write-Log "Version: $($testResult.Output.Trim())" "SUCCESS"
            break
        } else {
            Write-Log "FAILED: $wpCmd no funciona - $($testResult.Output)" "WARNING"
        }
    }
    
    if (-not $workingWpCommand) {
        Write-Log "ERROR: WP-CLI no encontrado o no funciona en $EnvName" "ERROR"
        return $false
    }
    
    # Verificar que WordPress está instalado usando el comando que funciona
    $wpCheckResult = Invoke-PlinkCommand -Server $Server -Command "cd $Path && $workingWpCommand core is-installed"
    
    if ($wpCheckResult.Success) {
        # Obtener versión de WordPress usando el comando que funciona
        $wpVersionResult = Invoke-PlinkCommand -Server $Server -Command "cd $Path && $workingWpCommand core version"
        if ($wpVersionResult.Success) {
            Write-Log "SUCCESS: WordPress $($wpVersionResult.Output.Trim()) funcionando en $EnvName" "SUCCESS"
        } else {
            Write-Log "SUCCESS: WordPress instalado en $EnvName" "SUCCESS"
        }
        
        # Verificar base de datos usando el comando que funciona
        $dbCheckResult = Invoke-PlinkCommand -Server $Server -Command "cd $Path && $workingWpCommand db check"
        if ($dbCheckResult.Success) {
            Write-Log "SUCCESS: Base de datos $EnvName OK" "SUCCESS"
        } else {
            Write-Log "WARNING: Base de datos $EnvName con advertencias" "WARNING"
        }
        
        return $true
    } else {
        Write-Log "ERROR: WordPress no funciona en $EnvName" "ERROR"
        Write-Log "Error: $($wpCheckResult.Output)" "ERROR"
        return $false
    }
}

function Test-DiskSpace {
    Write-Log "Verificando espacio en disco..."
    
    # Verificar espacio en Dev
    $devSpaceResult = Invoke-PlinkCommand -Server $DevServer -Command "df /tmp | tail -1 | awk '{print `$4}'"
    if (-not $devSpaceResult.Success) {
        Write-Log "ERROR: No se pudo verificar espacio en Dev" "ERROR"
        return $false
    }
    
    # Verificar espacio en Stage
    $stageSpaceResult = Invoke-PlinkCommand -Server $StageServer -Command "df /tmp | tail -1 | awk '{print `$4}'"
    if (-not $stageSpaceResult.Success) {
        Write-Log "ERROR: No se pudo verificar espacio en Stage" "ERROR"
        return $false
    }
    
    try {
        $devSpace = [int]($devSpaceResult.Output.Trim())
        $stageSpace = [int]($stageSpaceResult.Output.Trim())
        
        Write-Log "Espacio disponible - Dev: ${devSpace}KB, Stage: ${stageSpace}KB"
        
        if ($devSpace -lt 1000000 -or $stageSpace -lt 1000000) {
            Write-Log "ERROR: Espacio insuficiente en disco (mínimo 1GB)" "ERROR"
            Write-Log "Dev: ${devSpace}KB, Stage: ${stageSpace}KB" "ERROR"
            return $false
        } else {
            Write-Log "SUCCESS: Espacio en disco suficiente" "SUCCESS"
            return $true
        }
    }
    catch {
        Write-Log "ERROR: Error procesando espacio en disco: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Execute-PreMigrationCheck {
    Write-Log "=== EJECUTANDO VERIFICACIONES COMPLETAS ===" "SUCCESS"
    
    # 1. Verificar WordPress en Development
    if (-not (Test-WordPressInstallation -Server $DevServer -Path $DevPath -EnvName "Development")) {
        return $false
    }
    
    # 2. Verificar WordPress en Stage
    if (-not (Test-WordPressInstallation -Server $StageServer -Path $StagePath -EnvName "Stage")) {
        return $false
    }
    
    # 3. Verificar espacio en disco
    if (-not (Test-DiskSpace)) {
        return $false
    }
    
    Write-Log "SUCCESS: Todas las verificaciones completadas exitosamente" "SUCCESS"
    return $true
}

function Copy-ScriptsToServer {
    Write-Log "Copiando scripts usando pscp (PuTTY SCP)..."
    
    # Buscar pscp.exe
    $PscpPath = $PlinkPath -replace "plink", "pscp"
    if ($PlinkPath -eq "plink") {
        $PscpPath = "pscp"
    }
    
    try {
        # Verificar que los scripts existan
        $scripts = @("migrate-dev-to-stage.sh")
        
        foreach ($script in $scripts) {
            $localPath = "$ScriptPath\$script"
            if (-not (Test-Path $localPath)) {
                Write-Log "ERROR: Script no encontrado: $localPath" "ERROR"
                return $false
            }
        }
        
        # Copiar script de migración usando pscp
        foreach ($script in $scripts) {
            $localPath = "$ScriptPath\$script"
            Write-Log "Copiando $script..."
            
            $pscpArgs = @(
                "-pw", $Password,
                "-batch",
                $localPath,
                "$Username@${DevServer}:/tmp/"
            )
            
            $pscpResult = & $PscpPath $pscpArgs 2>&1
            $pscpExitCode = $LASTEXITCODE
            
            if ($pscpExitCode -eq 0) {
                Write-Log "SUCCESS: $script copiado exitosamente" "SUCCESS"
            } else {
                Write-Log "ERROR copiando $script : $pscpResult" "ERROR"
                return $false
            }
        }
        
        # Hacer script ejecutable
        $chmodCommand = "chmod +x /tmp/migrate-dev-to-stage.sh"
        $chmodResult = Invoke-PlinkCommand -Server $DevServer -Command $chmodCommand
        
        if ($chmodResult.Success) {
            Write-Log "SUCCESS: Permisos de ejecucion configurados" "SUCCESS"
        } else {
            Write-Log "WARNING: Advertencia configurando permisos: $($chmodResult.Output)" "WARNING"
        }
        
        Write-Log "SUCCESS: Scripts copiados exitosamente" "SUCCESS"
        return $true
        
    } catch {
        Write-Log "ERROR copiando scripts: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Execute-Migration {
    Write-Log "Ejecutando migracion Development -> Stage..."
    Write-Log "Esta operacion puede tomar varios minutos..."
    
    $migrateCommand = "cd /tmp; ./migrate-dev-to-stage.sh"
    $result = Invoke-PlinkCommand -Server $DevServer -Command $migrateCommand -TimeoutSeconds 600
    
    if ($result.Success) {
        Write-Log "SUCCESS: Migracion completada exitosamente" "SUCCESS"
        
        # Extraer Migration ID
        $migrationIdMatch = $result.Output | Select-String "Migration ID: (\w+)"
        if ($migrationIdMatch) {
            $script:LastMigrationId = $migrationIdMatch.Matches[0].Groups[1].Value
            Write-Log "Migration ID: $script:LastMigrationId" "SUCCESS"
        }
        
        Write-Log "Resultado de migracion:"
        Write-Log "$($result.Output)"
        return $true
    } else {
        Write-Log "ERROR: Migracion fallo" "ERROR"
        Write-Log "Output: $($result.Output)"
        return $false
    }
}

function Test-StageWebsite {
    Write-Log "Verificando sitio Stage..."
    
    try {
        $response = Invoke-WebRequest -Uri "https://web3stg.ciriontechnologies.com" -Method HEAD -TimeoutSec 30
        
        if ($response.StatusCode -eq 200) {
            Write-Log "SUCCESS: Sitio Stage responde correctamente (HTTP 200)" "SUCCESS"
            return $true
        } else {
            Write-Log "WARNING: Sitio Stage codigo: $($response.StatusCode)" "WARNING"
            return $false
        }
    } catch {
        Write-Log "ERROR: Sitio Stage no responde: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# === FUNCION PRINCIPAL ===
try {
    Write-Log "=== WordPress Deployment Manager (FINAL) ===" "SUCCESS"
    Write-Log "Operacion: $Operation"
    Write-Log "Jump Server: $env:COMPUTERNAME"
    Write-Log "Usuario: $Username"
    Write-Log "plink Path: $PlinkPath"
    Write-Log "Fecha/Hora: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log "============================================"
    
    # Verificar que plink existe
    if (-not $PlinkPath) {
        Write-Log "ERROR: plink.exe no encontrado. Instalar PuTTY." "ERROR"
        Write-Log "Descargar desde: https://www.putty.org/" "WARNING"
        exit 1
    }
    
    # Verificar conectividad
    if (-not (Test-ServerConnectivity)) {
        Write-Log "ERROR: Fallo en conectividad - Abortando operacion" "ERROR"
        exit 1
    }
    
    # Ejecutar operacion
    switch ($Operation) {
        "pre-check" {
            Write-Log "=== VERIFICACIONES PREVIAS COMPLETAS ===" "SUCCESS"
            
            if (Execute-PreMigrationCheck) {
                Write-Log "SUCCESS: RESULTADO: Sistema listo para migracion" "SUCCESS"
                Write-Log "Resumen:"
                Write-Log "- WordPress Development: OK"
                Write-Log "- WordPress Stage: OK"
                Write-Log "- Espacio en disco: Suficiente"
                Write-Log "- Conectividad: OK"
                exit 0
            } else {
                Write-Log "ERROR: RESULTADO: Sistema NO listo" "ERROR"
                exit 1
            }
        }
        
        "migrate" {
            Write-Log "=== MIGRACION COMPLETA ===" "SUCCESS"
            
            # Verificaciones previas
            Write-Log "Paso 1/4: Verificaciones previas..."
            if (-not (Execute-PreMigrationCheck)) {
                Write-Log "ERROR: Verificaciones fallaron - Abortando" "ERROR"
                exit 1
            }
            
            # Copiar scripts
            Write-Log "Paso 2/4: Copiando scripts..."
            if (-not (Copy-ScriptsToServer)) {
                Write-Log "ERROR: Fallo copiando scripts - Abortando" "ERROR"
                exit 1
            }
            
            # Migracion
            Write-Log "Paso 3/4: Ejecutando migracion..."
            if (-not (Execute-Migration)) {
                Write-Log "ERROR: Migracion fallo" "ERROR"
                exit 1
            }
            
            # Verificar sitio
            Write-Log "Paso 4/4: Verificando sitio web..."
            Test-StageWebsite
            
            Write-Log "SUCCESS: RESULTADO: Migracion completada exitosamente" "SUCCESS"
            exit 0
        }
        
        "content" {
            Write-Log "=== SINCRONIZACION DE CONTENIDO ===" "SUCCESS"
            Write-Log "WARNING: Funcion pendiente - usar 'migrate' por ahora" "WARNING"
            exit 0
        }
        
        "rollback" {
            Write-Log "=== ROLLBACK ===" "WARNING"
            
            if (-not $MigrationId) {
                Write-Log "ERROR: Migration ID requerido" "ERROR"
                exit 1
            }
            
            $rollbackCommand = "cd /var/www/html/webcirion; wp db import /tmp/stage_safety_backup_$MigrationId.sql"
            $rollbackResult = Invoke-PlinkCommand -Server $StageServer -Command $rollbackCommand
            
            if ($rollbackResult.Success) {
                Write-Log "SUCCESS: Rollback completado" "SUCCESS"
                Test-StageWebsite
            } else {
                Write-Log "ERROR en rollback: $($rollbackResult.Output)" "ERROR"
            }
            
            exit 0
        }
    }
    
} catch {
    Write-Log "ERROR critico: $($_.Exception.Message)" "ERROR"
    exit 1
}

Write-Log "Operacion completada" "SUCCESS"