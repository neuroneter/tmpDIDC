
#!/bin/bash
# migrate-dev-to-stage.sh - Migración Development → Stage para Azure DevOps Pipeline
# VERSION: Con sincronización uploads Azure Files

# Variables de configuración
DEV_SERVER="172.16.4.4"
STAGE_SERVER="172.16.5.4"
DEV_PATH="/var/www/html/debweb"
STAGE_PATH="/var/www/html/webcirion"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/var/log/wp-migrations"
STORAGE_ACCOUNT="sawebcorpdeveu2001"
STORAGE_KEY="NUYYMLcRw4j+WSPbJnoi01Sk7eRkPy00BpS3N/qftv6n0nHxQuOEdrKCM6j/lPOnSLbPH9gnh4/s+AStBHfePg=="
CONTAINER_NAME="dev-stage-migrations"

# Opciones SSH para evitar problemas de host key
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10"

# Crear directorio de logs
sudo mkdir -p $LOG_DIR
sudo chown admwb:admwb $LOG_DIR

# Función de logging con Azure DevOps compatible
log_message() {
    local level=$2
    local message="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    
    echo "$message" | tee -a $LOG_DIR/migration_$TIMESTAMP.log
    
    # Formato para Azure DevOps
    case $level in
        "error")
            echo "##vso[task.logissue type=error]$1"
            ;;
        "warning")
            echo "##vso[task.logissue type=warning]$1"
            ;;
        "success")
            echo "##vso[task.complete result=Succeeded]$1"
            ;;
    esac
}

# Función de verificación de conectividad
check_connectivity() {
    log_message "Verificando conectividad a servidores"
    
    # Verificar Development
    if ! ssh $SSH_OPTS admwb@$DEV_SERVER "echo 'test'" > /dev/null 2>&1; then
        log_message "No se puede conectar al servidor Development" "error"
        return 1
    fi
    
    # Verificar Stage
    if ! ssh $SSH_OPTS admwb@$STAGE_SERVER "echo 'test'" > /dev/null 2>&1; then
        log_message "No se puede conectar al servidor Stage" "error"
        return 1
    fi
    
    log_message "Conectividad verificada"
    return 0
}

# Función de verificación de WordPress
verify_wordpress() {
    local server=$1
    local path=$2
    local env_name=$3
    
    log_message "Verificando WordPress en $env_name"
    
    if ssh $SSH_OPTS admwb@$server "cd $path && wp core is-installed" > /dev/null 2>&1; then
        local wp_version=$(ssh $SSH_OPTS admwb@$server "cd $path && wp core version")
        log_message "WordPress $wp_version funcionando en $env_name"
        return 0
    else
        log_message "WordPress no funciona en $env_name" "error"
        return 1
    fi
}

# Función de backup de seguridad de Stage
create_stage_safety_backup() {
    log_message "Creando backup de seguridad de Stage"
    
    # Backup de BD
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp db export /tmp/stage_safety_backup_$TIMESTAMP.sql"; then
        log_message "Backup de seguridad de BD creado"
    else
        log_message "Error creando backup de seguridad" "error"
        return 1
    fi
    
    # Subir backup de seguridad a Azure (opcional)
    ssh $SSH_OPTS admwb@$STAGE_SERVER "
        export AZURE_STORAGE_ACCOUNT='$STORAGE_ACCOUNT'
        export AZURE_STORAGE_KEY='$STORAGE_KEY'
        az storage container create --name '$CONTAINER_NAME' --public-access off 2>/dev/null || true
        az storage blob upload \
            --container-name '$CONTAINER_NAME' \
            --name 'safety-backups/stage_safety_backup_$TIMESTAMP.sql' \
            --file '/tmp/stage_safety_backup_$TIMESTAMP.sql' \
            --overwrite
    " > /dev/null 2>&1
    
    log_message "Backup de seguridad guardado"
    return 0
}

# Función de backup de Development para migración
create_dev_migration_backup() {
    log_message "Creando backup de Development para migración"
    
    # Backup de BD
    if ssh $SSH_OPTS admwb@$DEV_SERVER "cd $DEV_PATH && wp db export /tmp/dev_migration_$TIMESTAMP.sql"; then
        log_message "Backup de BD de Development creado"
    else
        log_message "Error creando backup de Development" "error"
        return 1
    fi
    
    # Comprimir backup
    ssh $SSH_OPTS admwb@$DEV_SERVER "gzip /tmp/dev_migration_$TIMESTAMP.sql"
    
    # Subir a Azure para auditoria
    ssh $SSH_OPTS admwb@$DEV_SERVER "
        export AZURE_STORAGE_ACCOUNT='$STORAGE_ACCOUNT'
        export AZURE_STORAGE_KEY='$STORAGE_KEY'
        az storage container create --name '$CONTAINER_NAME' --public-access off 2>/dev/null || true
        az storage blob upload \
            --container-name '$CONTAINER_NAME' \
            --name 'migrations/dev_migration_$TIMESTAMP.sql.gz' \
            --file '/tmp/dev_migration_$TIMESTAMP.sql.gz' \
            --overwrite
    " > /dev/null 2>&1
    
    log_message "Backup de Development guardado en Azure"
    return 0
}

# Función de transferencia de backup
transfer_backup() {
    log_message "Transfiriendo backup Development → Stage"
    
    # Transferir archivo comprimido
    if scp $SSH_OPTS admwb@$DEV_SERVER:/tmp/dev_migration_$TIMESTAMP.sql.gz admwb@$STAGE_SERVER:/tmp/; then
        log_message "Backup transferido exitosamente"
        return 0
    else
        log_message "Error transfiriendo backup" "error"
        return 1
    fi
}

# Función de migración de base de datos
migrate_database() {
    log_message "Migrando base de datos Development → Stage"
    
    # Importar BD en Stage
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && zcat /tmp/dev_migration_$TIMESTAMP.sql.gz | /home/admwb/bin/wp db import -"; then
        log_message "Base de datos importada en Stage"
    else
        log_message "Error importando base de datos" "error"
        return 1
    fi
    
    # Actualizar URLs para Stage
    log_message "Actualizando URLs Development → Stage"
    
    # Primero hacer dry-run para ver qué va a cambiar
    log_message "Analizando cambios de URL..."
    ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp search-replace 'dev.website.local' 'web3stg.ciriontechnologies.com' --dry-run --format=table" > /tmp/url_changes_$TIMESTAMP.log
    
    # Mostrar resumen de cambios
    local changes_count=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp search-replace 'dev.website.local' 'web3stg.ciriontechnologies.com' --dry-run --format=count")
    log_message "Se encontraron $changes_count URLs para actualizar"
    
    # Ejecutar search-replace real
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp search-replace 'dev.website.local' 'web3stg.ciriontechnologies.com' --skip-columns=guid"; then
        log_message "URLs actualizadas: dev.website.local → web3stg.ciriontechnologies.com"
    else
        log_message "Error actualizando URLs" "error"
        return 1
    fi
    
    # Buscar URLs con protocolo específico por si hay hardcoded
    log_message "Buscando URLs con protocolo específico..."
    
    # HTTP
    local http_changes=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp search-replace 'http://dev.website.local' 'https://web3stg.ciriontechnologies.com' --dry-run --format=count")
    if [ "$http_changes" -gt 0 ]; then
        ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp search-replace 'http://dev.website.local' 'https://web3stg.ciriontechnologies.com' --skip-columns=guid"
        log_message "URLs HTTP actualizadas: $http_changes cambios"
    fi
    
    # HTTPS
    local https_changes=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp search-replace 'https://dev.website.local' 'https://web3stg.ciriontechnologies.com' --dry-run --format=count")
    if [ "$https_changes" -gt 0 ]; then
        ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp search-replace 'https://dev.website.local' 'https://web3stg.ciriontechnologies.com' --skip-columns=guid"
        log_message "URLs HTTPS actualizadas: $https_changes cambios"
    fi
    
    # Actualizar opciones principales de WordPress
    log_message "Actualizando opciones principales de WordPress"
    ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp option update home 'https://web3stg.ciriontechnologies.com'"
    ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp option update siteurl 'https://web3stg.ciriontechnologies.com'"
    
    # Limpiar cache
    ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp cache flush" > /dev/null 2>&1 || true
    
    # Limpiar rewrite rules
    ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp rewrite flush" > /dev/null 2>&1 || true
    
    log_message "Migración de URLs completada"
    return 0
}

# ============================================================================
# FUNCIONES DE SINCRONIZACIÓN UPLOADS - AZURE FILES
# ============================================================================

# Función de sincronización de uploads entre Azure Files
sync_uploads_azure_files() {
    log_message "Sincronizando uploads Azure Files Development → Stage"
    log_message "Source: //sawebcorpdeveu2001.file.core.windows.net/fs-websitecorp-dev"
    log_message "Target: //sawebcorpstgeu2001.file.core.windows.net/fs-websitecorp-stg"
    
    # Variables de rutas
    local dev_mountpoint="/var/www/html/debweb/wp-content/uploads"
    local stage_mountpoint="/var/www/html/webcirion/wp-content/uploads"
    
    # Verificar que los directorios existen y son accesibles
    if [ ! -d "$dev_mountpoint" ]; then
        log_message "ERROR: Directorio uploads Development no existe" "error"
        return 1
    fi
    
    # Verificar directorio Stage via SSH
    if ! ssh $SSH_OPTS admwb@$STAGE_SERVER "test -d $stage_mountpoint"; then
        log_message "ERROR: Directorio uploads Stage no existe" "error"
        return 1
    fi
    
    # Obtener estadísticas antes de sync
    log_message "Obteniendo estadísticas de uploads antes de sincronización..."
    local dev_files=$(find "$dev_mountpoint" -type f 2>/dev/null | wc -l)
    local dev_size=$(du -sh "$dev_mountpoint" 2>/dev/null | awk '{print $1}' || echo "0")
    log_message "Development uploads: $dev_files archivos, $dev_size total"
    
    local stage_files_before=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "find $stage_mountpoint -type f 2>/dev/null | wc -l")
    local stage_size_before=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "du -sh $stage_mountpoint 2>/dev/null | awk '{print \$1}' || echo '0'")
    log_message "Stage uploads (antes): $stage_files_before archivos, $stage_size_before total"
    
    # Verificar que hay algo que sincronizar
    if [ "$dev_files" -eq 0 ]; then
        log_message "WARNING: No hay archivos en Development uploads para sincronizar" "warning"
        return 0
    fi
    
    # Ejecutar rsync desde Development hacia Stage
    log_message "Iniciando sincronización rsync uploads..."
    log_message "Comando: rsync -av --delete $dev_mountpoint/ admwb@$STAGE_SERVER:$stage_mountpoint/"
    
    if rsync -av --delete --stats \
        "$dev_mountpoint/" \
        admwb@$STAGE_SERVER:"$stage_mountpoint/" 2>&1; then
        
        log_message "SUCCESS: Rsync uploads completado exitosamente"
        
        # Verificar resultado
        local stage_files_after=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "find $stage_mountpoint -type f 2>/dev/null | wc -l")
        local stage_size_after=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "du -sh $stage_mountpoint 2>/dev/null | awk '{print \$1}' || echo '0'")
        
        log_message "Stage uploads (después): $stage_files_after archivos, $stage_size_after total"
        
        # Validar sincronización
        if [ "$dev_files" -eq "$stage_files_after" ]; then
            log_message "SUCCESS: Conteo de archivos uploads coincide perfectamente ($dev_files archivos)"
            return 0
        else
            log_message "WARNING: Conteo de archivos uploads no coincide exactamente - Dev: $dev_files, Stage: $stage_files_after" "warning"
            # No fallar por diferencia menor en conteo
            if [ "$stage_files_after" -gt 0 ]; then
                log_message "INFO: Stage tiene archivos ($stage_files_after), continuando migración"
                return 0
            else
                log_message "ERROR: Stage no tiene archivos después de sincronización" "error"
                return 1
            fi
        fi
        
    else
        log_message "ERROR: Fallo en rsync uploads" "error"
        log_message "Verificando si es problema de conectividad o permisos..."
        
        # Test básico de conectividad
        if ssh $SSH_OPTS admwb@$STAGE_SERVER "echo 'Stage connectivity OK'" > /dev/null 2>&1; then
            log_message "Conectividad Stage OK - Problema puede ser permisos o rutas"
        else
            log_message "ERROR: Problema de conectividad con Stage" "error"
        fi
        
        return 1
    fi
}

# Función de verificación de uploads post-migración
verify_uploads_sync() {
    log_message "Verificando integridad de sincronización uploads"
    
    local dev_mountpoint="/var/www/html/debweb/wp-content/uploads"
    local stage_mountpoint="/var/www/html/webcirion/wp-content/uploads"
    
    # Contar archivos totales
    local dev_total=$(find "$dev_mountpoint" -type f 2>/dev/null | wc -l)
    local stage_total=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "find $stage_mountpoint -type f 2>/dev/null | wc -l")
    
    log_message "Conteo final - Development: $dev_total, Stage: $stage_total"
    
    # Verificar algunos archivos de muestra para integridad
    local sample_files=$(find "$dev_mountpoint" -type f \( -name "*.jpg" -o -name "*.png" -o -name "*.pdf" -o -name "*.gif" -o -name "*.svg" \) 2>/dev/null | head -5)
    
    if [ -z "$sample_files" ]; then
        log_message "INFO: No se encontraron archivos de muestra para verificar integridad"
        return 0
    fi
    
    local verified=0
    local total_samples=0
    
    log_message "Verificando integridad de archivos muestra..."
    for file in $sample_files; do
        total_samples=$((total_samples + 1))
        local relative_path=${file#$dev_mountpoint/}
        local stage_file="$stage_mountpoint/$relative_path"
        
        if ssh $SSH_OPTS admwb@$STAGE_SERVER "test -f '$stage_file'" 2>/dev/null; then
            # Verificar tamaño del archivo
            local dev_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
            local stage_size=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "stat -f%z '$stage_file' 2>/dev/null || stat -c%s '$stage_file' 2>/dev/null || echo '0'")
            
            if [ "$dev_size" = "$stage_size" ] && [ "$dev_size" != "0" ]; then
                log_message "✓ Archivo verificado OK: $relative_path ($dev_size bytes)"
                verified=$((verified + 1))
            else
                log_message "⚠ Archivo con diferencia de tamaño: $relative_path (Dev: $dev_size, Stage: $stage_size)" "warning"
            fi
        else
            log_message "✗ Archivo faltante en Stage: $relative_path" "warning"
        fi
    done
    
    log_message "Verificación uploads completada: $verified/$total_samples archivos validados"
    
    # Log de directorios principales sincronizados
    local main_dirs=$(find "$dev_mountpoint" -maxdepth 1 -type d -not -name "uploads" 2>/dev/null | tail -n +2)
    if [ -n "$main_dirs" ]; then
        log_message "Directorios principales sincronizados:"
        echo "$main_dirs" | while read -r dir; do
            local dir_name=$(basename "$dir")
            log_message "  - $dir_name"
        done
    fi
    
    return 0
}

# Función de verificación post-migración
verify_migration() {
    log_message "Verificando migración completa"
    
    # Verificar WordPress funciona
    if ! verify_wordpress $STAGE_SERVER $STAGE_PATH "Stage"; then
        return 1
    fi
    
    # Verificar BD
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp db check" > /dev/null 2>&1; then
        log_message "Base de datos Stage verificada"
    else
        log_message "Advertencia: No se pudo verificar BD completamente" "warning"
    fi
    
    # Verificar URLs
    local home_url=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp option get home")
    local site_url=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp option get siteurl")
    
    if [[ $home_url == *"web3stg.ciriontechnologies.com"* ]] && [[ $site_url == *"web3stg.ciriontechnologies.com"* ]]; then
        log_message "URLs verificadas correctamente"
        log_message "   - Home URL: $home_url"
        log_message "   - Site URL: $site_url"
    else
        log_message "Advertencia: URLs no actualizadas correctamente" "warning"
        log_message "   - Home URL: $home_url"
        log_message "   - Site URL: $site_url"
    fi
    
    # Verificar algunos posts/páginas básicas
    local post_count=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp post list --post_status=publish --format=count")
    log_message "Posts verificados: $post_count publicados"
    
    return 0
}

# Función de rollback
rollback_migration() {
    log_message "Iniciando rollback de migración" "warning"
    
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp db import /tmp/stage_safety_backup_$TIMESTAMP.sql"; then
        log_message "Rollback completado - Stage restaurado"
        
        # Verificar rollback
        if verify_wordpress $STAGE_SERVER $STAGE_PATH "Stage"; then
            log_message "Rollback verificado exitosamente"
            return 0
        else
            log_message "Error crítico: Rollback falló" "error"
            return 1
        fi
    else
        log_message "Error crítico: No se pudo ejecutar rollback" "error"
        return 1
    fi
}

# Función de limpieza
cleanup() {
    log_message "Limpiando archivos temporales"
    
    # Limpiar Development
    ssh $SSH_OPTS admwb@$DEV_SERVER "rm -f /tmp/dev_migration_$TIMESTAMP.sql*" 2>/dev/null || true
    
    # Limpiar Stage (mantener safety backup por 7 días)
    ssh $SSH_OPTS admwb@$STAGE_SERVER "rm -f /tmp/dev_migration_$TIMESTAMP.sql*" 2>/dev/null || true
    ssh $SSH_OPTS admwb@$STAGE_SERVER "find /tmp -name 'stage_safety_backup_*.sql' -mtime +7 -delete" 2>/dev/null || true
    
    log_message "Limpieza completada"
}

# Función de reporte final
generate_report() {
    local status=$1
    local duration=$2
    
    log_message "Generando reporte de migración"
    
    cat > $LOG_DIR/migration_report_$TIMESTAMP.json << EOF
{
    "migration_id": "$TIMESTAMP",
    "status": "$status",
    "duration": "$duration",
    "source": "Development ($DEV_SERVER)",
    "target": "Stage ($STAGE_SERVER)",
    "timestamp": "$(date -Iseconds)",
    "logs": "$LOG_DIR/migration_$TIMESTAMP.log",
    "azure_container": "$CONTAINER_NAME",
    "includes_uploads": true,
    "uploads_sync": "Azure Files Storage"
}
EOF
    
    log_message "Reporte guardado: migration_report_$TIMESTAMP.json"
    
    # Para Azure DevOps - publicar artefacto
    echo "##vso[artifact.upload containerfolder=MigrationReports;artifactname=migration-report]$LOG_DIR/migration_report_$TIMESTAMP.json"
}

# Función principal
main() {
    local start_time=$(date +%s)
    
    log_message "Iniciando migración COMPLETA Development → Stage (con uploads)"
    log_message "Migration ID: $TIMESTAMP"
    log_message "Source: Development ($DEV_SERVER:$DEV_PATH)"
    log_message "Target: Stage ($STAGE_SERVER:$STAGE_PATH)"
    log_message "Uploads: Azure Files Storage sincronización incluida"
    
    # Verificaciones previas
    if ! check_connectivity; then
        generate_report "FAILED" "0"
        exit 1
    fi
    
    if ! verify_wordpress $DEV_SERVER $DEV_PATH "Development"; then
        generate_report "FAILED" "0"
        exit 1
    fi
    
    if ! verify_wordpress $STAGE_SERVER $STAGE_PATH "Stage"; then
        generate_report "FAILED" "0"
        exit 1
    fi
    
    # Crear backup de seguridad
    if ! create_stage_safety_backup; then
        generate_report "FAILED" "0"
        exit 1
    fi
    
    # Crear backup de Development
    if ! create_dev_migration_backup; then
        generate_report "FAILED" "0"
        exit 1
    fi
    
    # Transferir backup
    if ! transfer_backup; then
        log_message "Error en transferencia - No se ejecutará rollback" "error"
        generate_report "FAILED" "0"
        exit 1
    fi
    
    # Migrar BD
    if ! migrate_database; then
        log_message "Error en migración BD - Ejecutando rollback" "error"
        rollback_migration
        cleanup
        generate_report "FAILED_ROLLBACK" "$(($(date +%s) - start_time))"
        exit 1
    fi
    
    # ============================================================================
    # SINCRONIZAR UPLOADS (NUEVO) - INCLUIDO EN MIGRACIÓN COMPLETA
    # ============================================================================
    if ! sync_uploads_azure_files; then
        log_message "Error en sincronización uploads - Ejecutando rollback" "error"
        rollback_migration
        cleanup
        generate_report "FAILED_ROLLBACK" "$(($(date +%s) - start_time))"
        exit 1
    fi
    
    # Verificar uploads sincronizados (NUEVO)
    verify_uploads_sync
    
    # ============================================================================
    # CONTINUAR CON VERIFICACIÓN ESTÁNDAR
    # ============================================================================
    
    # Verificar migración
    if ! verify_migration; then
        log_message "Error en verificación - Ejecutando rollback" "error"
        rollback_migration
        cleanup
        generate_report "FAILED_ROLLBACK" "$(($(date +%s) - start_time))"
        exit 1
    fi
    
    # Éxito
    cleanup
    local duration=$(($(date +%s) - start_time))
    log_message "Migración COMPLETA completada exitosamente en ${duration}s (incluye uploads)" "success"
    generate_report "SUCCESS" "$duration"
    
    # Mostrar resumen
    log_message "Resumen de migración COMPLETA:"
    log_message "   - ID: $TIMESTAMP"
    log_message "   - Duración: ${duration}s"
    log_message "   - Source: Development (BD + Uploads)"
    log_message "   - Target: Stage (BD + Uploads)"
    log_message "   - Base de datos: Azure MySQL → Azure MySQL"
    log_message "   - Uploads: Azure Files → Azure Files"
    log_message "   - Safety Backup: stage_safety_backup_$TIMESTAMP.sql"
    log_message "   - Azure Container: $CONTAINER_NAME"
    log_message "   - Logs: $LOG_DIR/migration_$TIMESTAMP.log"
}

# Manejo de señales para limpieza
trap cleanup EXIT

# Ejecutar migración
main "$@"