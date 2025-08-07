
# ============================================================================
# WordPress Azure MySQL Configuration Verification Script - SIMPLIFICADO
# ============================================================================

param(
    [Parameter(Mandatory=$false)]
    [switch]$DetailedOutput = $false
)

# Configuración
$DevServer = "172.16.4.4"
$StageServer = "172.16.5.4"
$Username = "admwb"
$Password = "Cirion#617"
$DevPath = "/var/www/html/debweb"
$StagePath = "/var/www/html/webcirion"

# Buscar plink
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

function Write-ColorLog {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Invoke-PlinkCommand {
    param([string]$Server, [string]$Command)
    
    if (-not $PlinkPath) {
        Write-ColorLog "ERROR: plink.exe no encontrado" "Red"
        return $null
    }
    
    try {
        $plinkArgs = @("-ssh", "-pw", $Password, "-batch", "$Username@$Server", $Command)
        $result = & $PlinkPath $plinkArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $result
        } else {
            return $null
        }
    } catch {
        return $null
    }
}

function Test-WPConfigAndDB {
    param([string]$Server, [string]$Path, [string]$EnvName)
    
    Write-ColorLog "`n======================================" "White"
    Write-ColorLog "🔍 VERIFICANDO $EnvName ($Server)" "Yellow"
    Write-ColorLog "======================================" "White"
    
    # 1. Verificar archivo wp-config.php existe
    Write-ColorLog "`n📁 Verificando archivo wp-config.php..." "Cyan"
    $fileCheck = Invoke-PlinkCommand -Server $Server -Command "ls -la $Path/wp-config.php"
    if ($fileCheck) {
        Write-ColorLog "✅ wp-config.php encontrado" "Green"
        if ($DetailedOutput) {
            Write-ColorLog "   $fileCheck" "Gray"
        }
    } else {
        Write-ColorLog "❌ wp-config.php NO encontrado en $Path" "Red"
        return $false
    }
    
    # 2. Obtener configuración de BD
    Write-ColorLog "`n🔧 Obteniendo configuración de base de datos..." "Cyan"
    
    $dbHost = Invoke-PlinkCommand -Server $Server -Command "grep 'DB_HOST' $Path/wp-config.php | head -1"
    $dbUser = Invoke-PlinkCommand -Server $Server -Command "grep 'DB_USER' $Path/wp-config.php | head -1"
    $dbName = Invoke-PlinkCommand -Server $Server -Command "grep 'DB_NAME' $Path/wp-config.php | head -1"
    
    Write-ColorLog "📋 Configuración encontrada:" "White"
    if ($dbHost) {
        Write-ColorLog "   $dbHost" "White"
    } else {
        Write-ColorLog "   DB_HOST: NO ENCONTRADO" "Red"
    }
    
    if ($dbUser) {
        Write-ColorLog "   $dbUser" "White"
    } else {
        Write-ColorLog "   DB_USER: NO ENCONTRADO" "Red"
    }
    
    if ($dbName) {
        Write-ColorLog "   $dbName" "White"
    } else {
        Write-ColorLog "   DB_NAME: NO ENCONTRADO" "Yellow"
    }
    
    # 3. Verificar si usa Azure MySQL
    Write-ColorLog "`n🎯 Validando Azure MySQL..." "Cyan"
    $isAzureMySQL = $false
    
    if ($dbHost) {
        if ($dbHost -like "*dbdev.website.local*" -or 
            $dbHost -like "*172.16.8.6*" -or
            $dbHost -like "*dbmysqlwebcorpdeveu2001*") {
            Write-ColorLog "✅ Configurado para Azure MySQL Development" "Green"
            $isAzureMySQL = $true
        } elseif ($dbHost -like "*dbstg.website.local*" -or 
                  $dbHost -like "*172.16.8.5*" -or
                  $dbHost -like "*dbmysqlwebcorpstgeu2001*") {
            Write-ColorLog "✅ Configurado para Azure MySQL Stage" "Green"
            $isAzureMySQL = $true
        } elseif ($dbHost -like "*localhost*" -or $dbHost -like "*127.0.0.1*") {
            Write-ColorLog "❌ Configurado para BD LOCAL - NO Azure MySQL" "Red"
        } else {
            Write-ColorLog "⚠️  Configuración BD desconocida" "Yellow"
        }
    }
    
    # 4. Test conectividad WordPress
    Write-ColorLog "`n🔌 Verificando conectividad WordPress..." "Cyan"
    $wpCheck = Invoke-PlinkCommand -Server $Server -Command "cd $Path; wp db check"
    
    if ($wpCheck -and $wpCheck -like "*Success*") {
        Write-ColorLog "✅ Conectividad BD WordPress: OK" "Green"
        if ($DetailedOutput) {
            Write-ColorLog "   Output: $wpCheck" "Gray"
        }
        
        # Información adicional
        $wpVersion = Invoke-PlinkCommand -Server $Server -Command "cd $Path; wp core version"
        if ($wpVersion) {
            Write-ColorLog "   WordPress Version: $wpVersion" "Cyan"
        }
        
        $dbSize = Invoke-PlinkCommand -Server $Server -Command "cd $Path; wp db size --human-readable"
        if ($dbSize -and $dbSize -notlike "*Error*") {
            Write-ColorLog "   Database Size: $dbSize" "Cyan"
        }
        
        $postCount = Invoke-PlinkCommand -Server $Server -Command "cd $Path; wp post list --post_status=publish --format=count"
        if ($postCount) {
            Write-ColorLog "   Published Posts: $postCount" "Cyan"
        }
        
        return $true
    } else {
        Write-ColorLog "❌ Conectividad BD WordPress: FALLO" "Red"
        if ($wpCheck) {
            Write-ColorLog "   Error: $wpCheck" "Red"
        }
        return $false
    }
}

# ============================================================================
# EJECUCIÓN PRINCIPAL
# ============================================================================

Write-ColorLog "============================================" "White"
Write-ColorLog "🚀 VERIFICACIÓN COMPLETA WordPress Azure MySQL" "White"
Write-ColorLog "============================================" "White"

if (-not $PlinkPath) {
    Write-ColorLog "❌ ERROR: plink.exe no encontrado. Instalar PuTTY." "Red" 
    Write-ColorLog "   Descargar desde: https://www.putty.org/" "Yellow"
    exit 1
}

Write-ColorLog "🔧 plink encontrado en: $PlinkPath" "Green"

# Test conectividad básica
Write-ColorLog "`n🌐 Verificando conectividad SSH..." "Cyan"
$devPing = Test-Connection -ComputerName $DevServer -Count 1 -Quiet
$stagePing = Test-Connection -ComputerName $StageServer -Count 1 -Quiet

Write-ColorLog "   Dev Server ($DevServer): $(if($devPing) { '✅ Online' } else { '❌ Offline' })" $(if($devPing) { "Green" } else { "Red" })
Write-ColorLog "   Stage Server ($StageServer): $(if($stagePing) { '✅ Online' } else { '❌ Offline' })" $(if($stagePing) { "Green" } else { "Red" })

if (-not $devPing -or -not $stagePing) {
    Write-ColorLog "`n❌ ERROR: Servidores no accesibles. Verificar conectividad de red." "Red"
    exit 1
}

# Verificar configuraciones y conectividad
$devResult = Test-WPConfigAndDB -Server $DevServer -Path $DevPath -EnvName "DEVELOPMENT"
$stageResult = Test-WPConfigAndDB -Server $StageServer -Path $StagePath -EnvName "STAGE"

# Resumen final
Write-ColorLog "`n" "White"
Write-ColorLog "============================================" "White"
Write-ColorLog "📊 RESUMEN FINAL" "White"  
Write-ColorLog "============================================" "White"

Write-ColorLog "`n🏗️  DEVELOPMENT: $(if($devResult) { '✅ OK' } else { '❌ PROBLEMAS' })" $(if($devResult) { "Green" } else { "Red" })
Write-ColorLog "🎭 STAGE: $(if($stageResult) { '✅ OK' } else { '❌ PROBLEMAS' })" $(if($stageResult) { "Green" } else { "Red" })

if ($devResult -and $stageResult) {
    Write-ColorLog "`n🎯 RESULTADO:" "White"
    Write-ColorLog "✅ SISTEMA LISTO - Ambos ambientes configurados correctamente" "Green"
    Write-ColorLog "✅ Scripts de migración deberían funcionar sin problemas" "Green"
    Write-ColorLog "`n🚀 Puedes ejecutar:" "Yellow"
    Write-ColorLog "   .\WordPressDeploymentManager.ps1 -Operation 'pre-check'" "Cyan"
    Write-ColorLog "   .\WordPressDeploymentManager.ps1 -Operation 'migrate'" "Cyan"
    exit 0
} else {
    Write-ColorLog "`n🎯 RESULTADO:" "White"
    Write-ColorLog "❌ PROBLEMAS DETECTADOS - Revisar configuración" "Red"
    Write-ColorLog "`n🔧 Recomendaciones:" "Yellow"
    if (-not $devResult) {
        Write-ColorLog "   • Verificar wp-config.php en Development" "White"
        Write-ColorLog "   • Verificar conectividad Azure MySQL Development" "White"
    }
    if (-not $stageResult) {
        Write-ColorLog "   • Verificar wp-config.php en Stage" "White"
        Write-ColorLog "   • Verificar conectividad Azure MySQL Stage" "White"
    }
    exit 1
}