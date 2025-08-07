# DEBUG RSYNC DRY-RUN - Paso a paso

Write-Host "=== DEBUG RSYNC DRY-RUN ===" -ForegroundColor Cyan

Write-Host ""
Write-Host "1. Test RSYNC básico:" -ForegroundColor Yellow
$basicRsync = & plink -ssh -pw "Cirion#617" -batch "admwb@172.16.5.4" "rsync --version"
Write-Host "RSYNC version: $basicRsync" -ForegroundColor Green

Write-Host ""
Write-Host "2. Test paths existen:" -ForegroundColor Yellow
$devPathTest = & plink -ssh -pw "Cirion#617" -batch "admwb@172.16.5.4" "ls -ld /var/www/html/debweb/wp-content/uploads"
$stagePathTest = & plink -ssh -pw "Cirion#617" -batch "admwb@172.16.5.4" "ls -ld /var/www/html/webcirion/wp-content/uploads"
Write-Host "Dev path: $devPathTest" -ForegroundColor Green
Write-Host "Stage path: $stagePathTest" -ForegroundColor Green

Write-Host ""
Write-Host "3. Test RSYNC simple (sin opciones complejas):" -ForegroundColor Yellow
$simpleRsync = & plink -ssh -pw "Cirion#617" -batch "admwb@172.16.5.4" "rsync -n /var/www/html/debweb/wp-content/uploads/ /var/www/html/webcirion/wp-content/uploads/"
Write-Host "RSYNC simple result: $simpleRsync" -ForegroundColor Green

Write-Host ""
Write-Host "4. Test RSYNC con --dry-run:" -ForegroundColor Yellow
$dryRunSimple = & plink -ssh -pw "Cirion#617" -batch "admwb@172.16.5.4" "rsync --dry-run /var/www/html/debweb/wp-content/uploads/ /var/www/html/webcirion/wp-content/uploads/"
Write-Host "RSYNC dry-run result: $dryRunSimple" -ForegroundColor Green

Write-Host ""
Write-Host "5. Test RSYNC con verbose:" -ForegroundColor Yellow
$verboseRsync = & plink -ssh -pw "Cirion#617" -batch "admwb@172.16.5.4" "rsync -v --dry-run /var/www/html/debweb/wp-content/uploads/ /var/www/html/webcirion/wp-content/uploads/ | head -5"
Write-Host "RSYNC verbose result: $verboseRsync" -ForegroundColor Green

Write-Host ""
Write-Host "6. Test comando completo problemático:" -ForegroundColor Yellow
$fullCommand = & plink -ssh -pw "Cirion#617" -batch "admwb@172.16.5.4" "rsync -av --dry-run --itemize-changes /var/www/html/debweb/wp-content/uploads/ /var/www/html/webcirion/wp-content/uploads/ | head -5"
Write-Host "Comando completo result: $fullCommand" -ForegroundColor Green

Write-Host ""
Write-Host "7. Test permisos de lectura Dev desde Stage:" -ForegroundColor Yellow
$readPermTest = & plink -ssh -pw "Cirion#617" -batch "admwb@172.16.5.4" "ls /var/www/html/debweb/wp-content/uploads/ | head -3"
Write-Host "Read permissions: $readPermTest" -ForegroundColor Green

Write-Host ""
Write-Host "=== ANÁLISIS ===" -ForegroundColor Cyan
Write-Host "Si alguno de los tests arriba falló, ese es el problema." -ForegroundColor White
Write-Host "El más probable es que Stage no pueda leer Dev uploads directamente." -ForegroundColor Yellow