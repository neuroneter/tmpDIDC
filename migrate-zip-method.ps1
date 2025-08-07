# migrate-zip-method.ps1 - Migración usando ZIP (método más confiable)
$DevServer = "172.16.4.4"
$StageServer = "172.16.5.4"
$Username = "admwb"
$Password = "Cirion#617"
$DevPath = "/var/www/html/debweb"
$StagePath = "/var/www/html/webcirion"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

Write-Host "============================================" -ForegroundColor Magenta
Write-Host "MIGRACIÓN UPLOADS - MÉTODO ZIP" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "Proceso: Dev ZIP → Transfer → Stage Backup → Replace → Verify" -ForegroundColor Yellow
Write-Host ""

# Mostrar estado actual
Write-Host "=== ESTADO ACTUAL ===" -ForegroundColor Cyan
$devCount = (& plink -ssh -pw $Password -batch "$Username@$DevServer" "find $DevPath/wp-content/uploads -type f | wc -l").Trim()
$devSize = (& plink -ssh -pw $Password -batch "$Username@$DevServer" "du -sh $DevPath/wp-content/uploads" | ForEach-Object { $_.Split()[0] })

Write-Host "Development uploads: $devCount archivos, $devSize" -ForegroundColor Green
Write-Host "Después: Stage tendrá exactamente $devCount archivos" -ForegroundColor Yellow
Write-Host ""

$confirm = Read-Host "¿Continuar con migración ZIP? (S/N)"
if ($confirm -notlike "S*" -and $confirm -notlike "Y*") {
    Write-Host "Migración cancelada" -ForegroundColor Yellow
    exit 0
}

Write-Host ""

# PASO 1: Crear ZIP en Development
Write-Host "PASO 1: Creando ZIP completo en Development..." -ForegroundColor Cyan
$zipFile = "dev_uploads_complete_$timestamp.zip"

& plink -ssh -pw $Password -batch "$Username@$DevServer" "cd $DevPath/wp-content && zip -r /tmp/$zipFile uploads/"

# Verificar ZIP creado
$zipInfo = & plink -ssh -pw $Password -batch "$Username@$DevServer" "ls -lh /tmp/$zipFile"
Write-Host "✓ ZIP creado: $zipInfo" -ForegroundColor Green

# PASO 2: Transferir ZIP a Stage vía Windows
Write-Host "`nPASO 2: Transfiriendo ZIP Development → Stage..." -ForegroundColor Cyan
$localZip = "C:\temp\$zipFile"
$null = New-Item -Path "C:\temp" -ItemType Directory -Force

Write-Host "  Descargando desde Development..." -ForegroundColor Yellow
& pscp -pw $Password -batch "admwb@$DevServer`:/tmp/$zipFile" $localZip

Write-Host "  Subiendo a Stage..." -ForegroundColor Yellow
& pscp -pw $Password -batch $localZip "admwb@$StageServer`:/tmp/"

Remove-Item $localZip -Force
Write-Host "✓ ZIP transferido a Stage" -ForegroundColor Green

# PASO 3: Backup completo de Stage actual
Write-Host "`nPASO 3: Creando backup completo Stage (para rollback)..." -ForegroundColor Cyan
$stageBackupZip = "stage_uploads_backup_$timestamp.zip"

& plink -ssh -pw $Password -batch "$Username@$StageServer" "cd $StagePath/wp-content && zip -r /tmp/$stageBackupZip uploads/"

$backupInfo = & plink -ssh -pw $Password -batch "$Username@$StageServer" "ls -lh /tmp/$stageBackupZip"
Write-Host "✓ Backup Stage creado: $backupInfo" -ForegroundColor Green

# PASO 4: Eliminar contenido actual de uploads Stage
Write-Host "`nPASO 4: Eliminando contenido actual uploads Stage..." -ForegroundColor Cyan
Write-Host "  ADVERTENCIA: Eliminando todo el contenido actual..." -ForegroundColor Red

& plink -ssh -pw $Password -batch "$Username@$StageServer" "rm -rf $StagePath/wp-content/uploads/*"
& plink -ssh -pw $Password -batch "$Username@$StageServer" "rm -rf $StagePath/wp-content/uploads/.*" 2>$null

Write-Host "✓ Contenido uploads Stage eliminado" -ForegroundColor Green

# PASO 5: Extraer ZIP Development en Stage
Write-Host "`nPASO 5: Extrayendo uploads Development en Stage..." -ForegroundColor Cyan

& plink -ssh -pw $Password -batch "$Username@$StageServer" "cd $StagePath/wp-content && unzip -o /tmp/$zipFile"

Write-Host "✓ ZIP extraído en Stage" -ForegroundColor Green

# PASO 6: Verificación completa
Write-Host "`nPASO 6: Verificación completa..." -ForegroundColor Cyan

# Contar archivos Stage después
$stageCountAfter = (& plink -ssh -pw $Password -batch "$Username@$StageServer" "find $StagePath/wp-content/uploads -type f | wc -l").Trim()
$stageSizeAfter = (& plink -ssh -pw $Password -batch "$Username@$StageServer" "du -sh $StagePath/wp-content/uploads" | ForEach-Object { $_.Split()[0] })

# Verificar archivo test específico
$testFileCheck = & plink -ssh -pw $Password -batch "$Username@$StageServer" "ls $StagePath/wp-content/uploads/test-migration* 2>/dev/null && echo 'TEST_FOUND' || echo 'TEST_NOT_FOUND'"

Write-Host "Resultado verificación:" -ForegroundColor Green
Write-Host "  Development: $devCount archivos ($devSize)" -ForegroundColor White
Write-Host "  Stage: $stageCountAfter archivos ($stageSizeAfter)" -ForegroundColor White
Write-Host "  Archivo test: $testFileCheck" -ForegroundColor White

# Evaluación resultado
if ($devCount -eq $stageCountAfter) {
    Write-Host "`n✓ PERFECTO: Conteos exactos" -ForegroundColor Green
    if ($testFileCheck -like "*TEST_FOUND*") {
        Write-Host "✓ PERFECTO: Archivo test encontrado" -ForegroundColor Green
        Write-Host "`n🎉 MIGRACIÓN ZIP EXITOSA" -ForegroundColor Green
    } else {
        Write-Host "⚠ Conteos coinciden pero archivo test no encontrado" -ForegroundColor Yellow
    }
} else {
    Write-Host "`n⚠ ADVERTENCIA: Conteos diferentes" -ForegroundColor Yellow
    Write-Host "   Development: $devCount vs Stage: $stageCountAfter" -ForegroundColor Yellow
}

# PASO 7: Limpieza archivos temporales
Write-Host "`nPASO 7: Limpieza archivos temporales..." -ForegroundColor Cyan

& plink -ssh -pw $Password -batch "$Username@$DevServer" "rm -f /tmp/$zipFile"
& plink -ssh -pw $Password -batch "$Username@$StageServer" "rm -f /tmp/$zipFile"

Write-Host "✓ Archivos temporales eliminados" -ForegroundColor Green

# PASO 8: Información rollback
Write-Host "`n============================================" -ForegroundColor Green
Write-Host "MIGRACIÓN ZIP COMPLETADA" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Migration ID: $timestamp" -ForegroundColor Cyan
Write-Host ""
Write-Host "ROLLBACK disponible:" -ForegroundColor Yellow
Write-Host "  Archivo: /tmp/$stageBackupZip" -ForegroundColor Cyan
Write-Host "  Comando: cd $StagePath/wp-content && rm -rf uploads/* && unzip /tmp/$stageBackupZip" -ForegroundColor Gray
Write-Host ""
Write-Host "VERIFICACIÓN:" -ForegroundColor Yellow
Write-Host "  1. Verifica en FileZilla que aparece: test-migration-20250807-163901.txt" -ForegroundColor White
Write-Host "  2. Verifica que el sitio web sigue funcionando" -ForegroundColor White
Write-Host "  3. Total archivos Stage: $stageCountAfter (debe ser igual a Dev: $devCount)" -ForegroundColor White
Write-Host ""

# Test sitio web
Write-Host "Test rápido sitio web:" -ForegroundColor Cyan
try {
    $webTest = Invoke-WebRequest -Uri "https://web3stg.ciriontechnologies.com" -Method HEAD -TimeoutSec 15 -ErrorAction Stop
    Write-Host "✓ Sitio web respondiendo: HTTP $($webTest.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "⚠ Sitio web: $($_.Exception.Message)" -ForegroundColor Yellow
}