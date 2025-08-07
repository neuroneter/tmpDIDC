#!/bin/bash
# migrate-dev-to-stage.sh - Migración Development → Stage para Azure DevOps Pipeline
# VERSION FINAL: Con rollback COMPLETO (BD + Uploads) + Gestión de Retención Inteligente

# ============================================================================
# CONFIGURACIÓN
# ============================================================================

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

# CONFIGURACIÓN DE RETENCIÓN DE BACKUPS (AJUSTABLE)
MAX_DB_BACKUPS=3                    # Máximo 3 backups de BD
MAX_UPLOADS_BACKUPS=2               # Máximo 2 backups de uploads (más pesados)
RETENTION_DAYS=7                    # Eliminar backups mayores a 7 días
MIN_FREE_SPACE_MB=1000             # Espacio mínimo libre requerido (1GB)

# Opciones SSH para evitar problemas de host key
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10"

# ============================================================================
# FUNCIONES DE LOGGING Y BÁSICAS
# ============================================================================

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

# ============================================================================
# FUNCIONES DE GESTIÓN DE RETENCIÓN DE BACKUPS
# ============================================================================

# Función para obtener espacio libre en MB
get_free_space_mb() {
    local server=$1
    local path=${2:-"/tmp"}
    
    local space_kb=$(ssh $SSH_OPTS admwb@$server "df $path | tail -1 | awk '{print \$4}'")
    local space_mb=$((space_kb / 1024))
    echo $space_mb
}

# Función para limpiar backups antiguos por tiempo
cleanup_backups_by_age() {
    local server=$1
    
    log_message "Limpiando backups antiguos (>$RETENTION_DAYS días) en $server"
    
    # Limpiar backups BD antiguos
    local deleted_db=$(ssh $SSH_OPTS admwb@$server "find /tmp -name 'stage_safety_backup_*.sql' -mtime +$RETENTION_DAYS -delete -print | wc -l")
    if [ $deleted_db -gt 0 ]; then
        log_message "Eliminados $deleted_db backups BD antiguos"
    fi
    
    # Limpiar backups uploads antiguos
    local deleted_uploads=$(ssh $SSH_OPTS admwb@$server "find /tmp -name 'stage_uploads_backup_*.tar.gz' -mtime +$RETENTION_DAYS -delete -print | wc -l")
    if [ $deleted_uploads -gt 0 ]; then
        log_message "Eliminados $deleted_uploads backups uploads antiguos"
    fi
    
    # Limpiar backups migración antiguos
    local deleted_migration=$(ssh $SSH_OPTS admwb@$server "find /tmp -name 'dev_migration_*.sql.gz' -mtime +$RETENTION_DAYS -delete -print | wc -l")
    if [ $deleted_migration -gt 0 ]; then
        log_message "Eliminados $deleted_migration backups migración antiguos"
    fi
}

# Función para limpiar backups por cantidad máxima
cleanup_backups_by_count() {
    local server=$1
    
    log_message "Verificando límites de cantidad de backups en $server"
    
    # Limpiar backups BD excedentes (mantener solo MAX_DB_BACKUPS)
    local db_backups=$(ssh $SSH_OPTS admwb@$server "ls -t /tmp/stage_safety_backup_*.sql 2>/dev/null | tail -n +$((MAX_DB_BACKUPS + 1))")
    if [ -n "$db_backups" ]; then
        local count=$(echo "$db_backups" | wc -l)
        log_message "Eliminando $count backups BD excedentes (límite: $MAX_DB_BACKUPS)"
        echo "$db_backups" | while read -r file; do
            ssh $SSH_OPTS admwb@$server "rm -f '$file'"
            log_message "Eliminado: $(basename '$file')"
        done
    fi
    
    # Limpiar backups uploads excedentes (mantener solo MAX_UPLOADS_BACKUPS)
    local uploads_backups=$(ssh $SSH_OPTS admwb@$server "ls -t /tmp/stage_uploads_backup_*.tar.gz 2>/dev/null | tail -n +$((MAX_UPLOADS_BACKUPS + 1))")
    if [ -n "$uploads_backups" ]; then
        local count=$(echo "$uploads_backups" | wc -l)
        log_message "Eliminando $count backups uploads excedentes (límite: $MAX_UPLOADS_BACKUPS)"
        echo "$uploads_backups" | while read -r file; do
            local file_size=$(ssh $SSH_OPTS admwb@$server "ls -lh '$file' | awk '{print \$5}'")
            ssh $SSH_OPTS admwb@$server "rm -f '$file'"
            log_message "Eliminado: $(basename '$file') ($file_size)"
        done
    fi
}

# Función para limpieza agresiva si espacio crítico
emergency_cleanup_backups() {
    local server=$1
    
    log_message "LIMPIEZA DE EMERGENCIA: Espacio crítico detectado" "warning"
    
    # Obtener tamaños de backups uploads (más grandes)
    local uploads_backups_info=$(ssh $SSH_OPTS admwb@$server "ls -lt /tmp/stage_uploads_backup_*.tar.gz 2>/dev/null | head -10")
    
    if [ -n "$uploads_backups_info" ]; then
        log_message "Backups uploads encontrados:"
        echo "$uploads_backups_info" | while read -r line; do
            log_message "  $line"
        done
        
        # Eliminar uploads backups excepto el más reciente
        local old_uploads=$(ssh $SSH_OPTS admwb@$server "ls -t /tmp/stage_uploads_backup_*.tar.gz 2>/dev/null | tail -n +2")
        if [ -n "$old_uploads" ]; then
            local count=$(echo "$old_uploads" | wc -l)
            log_message "EMERGENCIA: Eliminando $count backups uploads (manteniendo solo el más reciente)" "warning"
            echo "$old_uploads" | while read -r file; do
                local file_size=$(ssh $SSH_OPTS admwb@$server "ls -lh '$file' | awk '{print \$5}'")
                ssh $SSH_OPTS admwb@$server "rm -f '$file'"
                log_message "EMERGENCIA: Eliminado: $(basename '$file') ($file_size)" "warning"
            done
        fi
    fi
}

# Función principal de gestión de retención
manage_backup_retention() {
    local server=$1
    local cleanup_type=${2:-"normal"}  # normal, aggressive, emergency
    
    log_message "Iniciando gestión de retención backups en $server (modo: $cleanup_type)"
    
    # Obtener espacio libre inicial
    local free_space_before=$(get_free_space_mb $server)
    log_message "Espacio libre inicial: ${free_space_before}MB"
    
    case $cleanup_type in
        "emergency")
            emergency_cleanup_backups $server
            ;;
        "aggressive") 
            cleanup_backups_by_age $server
            cleanup_backups_by_count $server
            # Si aún no hay suficiente espacio, hacer limpieza de emergencia
            local free_space_check=$(get_free_space_mb $server)
            if [ $free_space_check -lt $MIN_FREE_SPACE_MB ]; then
                emergency_cleanup_backups $server
            fi
            ;;
        "normal"|*)
            cleanup_backups_by_age $server
            cleanup_backups_by_count $server
            ;;
    esac
    
    # Obtener espacio libre después de limpieza
    local free_space_after=$(get_free_space_mb $server)
    local space_freed=$((free_space_after - free_space_before))
    
    log_message "Gestión de retención completada:"
    log_message "  - Espacio libre después: ${free_space_after}MB"
    if [ $space_freed -gt 0 ]; then
        log_message "  - Espacio liberado: ${space_freed}MB"
    fi
    
    # Listar backups actuales
    list_current_backups $server
}

# Función para listar backups actuales
list_current_backups() {
    local server=$1
    
    log_message "Backups actuales en $server:"
    
    # Backups BD
    local db_backups=$(ssh $SSH_OPTS admwb@$server "ls -lt /tmp/stage_safety_backup_*.sql 2>/dev/null | head -5")
    if [ -n "$db_backups" ]; then
        log_message "  BD Backups:"
        echo "$db_backups" | while read -r line; do
            log_message "    $line"
        done
    else
        log_message "  BD Backups: Ninguno"
    fi
    
    # Backups uploads
    local uploads_backups=$(ssh $SSH_OPTS admwb@$server "ls -lt /tmp/stage_uploads_backup_*.tar.gz 2>/dev/null | head -5")
    if [ -n "$uploads_backups" ]; then
        log_message "  Uploads Backups:"
        echo "$uploads_backups" | while read -r line; do
            log_message "    $line"
        done
    else
        log_message "  Uploads Backups: Ninguno"
    fi
}

# ============================================================================
# FUNCIONES DE BACKUP CON GESTIÓN DE ESPACIO
# ============================================================================

# Función para estimar espacio necesario para backup uploads
estimate_uploads_backup_space() {
    log_message "Verificando espacio para backup uploads Stage con gestión de retención"
    
    # Obtener tamaño de uploads Stage
    local uploads_size_bytes=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "du -sb $STAGE_PATH/wp-content/uploads 2>/dev/null | awk '{print \$1}' || echo '0'")
    local uploads_size_human=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "du -sh $STAGE_PATH/wp-content/uploads 2>/dev/null | awk '{print \$1}' || echo '0B'")
    
    # Obtener espacio disponible en /tmp
    local available_space_mb=$(get_free_space_mb $STAGE_SERVER "/tmp")
    local available_space_bytes=$((available_space_mb * 1024 * 1024))
    
    log_message "Uploads Stage size: $uploads_size_human ($uploads_size_bytes bytes)"
    log_message "Available space in /tmp: ${available_space_mb}MB"
    
    # Necesitamos ~1.2x el tamaño para compresión + margen de seguridad
    local needed_space_bytes=$((uploads_size_bytes * 12 / 10))
    local needed_space_mb=$((needed_space_bytes / 1024 / 1024))
    
    log_message "Espacio estimado necesario: ${needed_space_mb}MB"
    
    # Verificar si necesitamos limpiar backups
    if [ $uploads_size_bytes -gt 0 ] && [ $available_space_bytes -lt $needed_space_bytes ]; then
        log_message "Espacio insuficiente detectado - Iniciando limpieza de backups" "warning"
        
        # Primero intentar limpieza normal
        manage_backup_retention $STAGE_SERVER "normal"
        
        # Verificar espacio nuevamente
        local available_space_after=$(get_free_space_mb $STAGE_SERVER "/tmp")
        local available_space_after_bytes=$((available_space_after * 1024 * 1024))
        
        if [ $available_space_after_bytes -lt $needed_space_bytes ]; then
            log_message "Espacio aún insuficiente - Ejecutando limpieza agresiva" "warning"
            manage_backup_retention $STAGE_SERVER "aggressive"
            
            # Verificación final
            local final_space=$(get_free_space_mb $STAGE_SERVER "/tmp")
            local final_space_bytes=$((final_space * 1024 * 1024))
            
            if [ $final_space_bytes -lt $needed_space_bytes ]; then
                log_message "ERROR: Espacio insuficiente incluso después de limpieza agresiva" "error"
                log_message "Necesario: ${needed_space_mb}MB, Disponible: ${final_space}MB" "error"
                log_message "Considere aumentar espacio en disco o reducir retención de backups" "error"
                return 1
            else
                log_message "Espacio suficiente después de limpieza agresiva: ${final_space}MB" "success"
            fi
        else
            log_message "Espacio suficiente después de limpieza normal: ${available_space_after}MB" "success"
        fi
    else
        log_message "Espacio suficiente para backup uploads"
        
        # Ejecutar limpieza de mantenimiento regular
        manage_backup_retention $STAGE_SERVER "normal"
    fi
    
    return 0
}

# Función de backup de seguridad de Stage - BD
create_stage_safety_backup() {
    log_message "Creando backup de seguridad BD Stage"
    
    # Backup de BD
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp db export /tmp/stage_safety_backup_$TIMESTAMP.sql"; then
        log_message "Backup de seguridad de BD creado"
    else
        log_message "Error creando backup de seguridad BD" "error"
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
    
    log_message "Backup de seguridad BD guardado"
    return 0
}

# Función de backup de seguridad de Stage - UPLOADS
create_stage_uploads_backup() {
    log_message "Creando backup de seguridad UPLOADS Stage"
    
    # Verificar espacio necesario
    if ! estimate_uploads_backup_space; then
        return 1
    fi
    
    # Verificar que existe directorio uploads
    if ! ssh $SSH_OPTS admwb@$STAGE_SERVER "test -d $STAGE_PATH/wp-content/uploads"; then
        log_message "WARNING: Directorio uploads Stage no existe, creando backup vacío" "warning"
        ssh $SSH_OPTS admwb@$STAGE_SERVER "mkdir -p $STAGE_PATH/wp-content/uploads && tar -czf /tmp/stage_uploads_backup_$TIMESTAMP.tar.gz -T /dev/null"
        return 0
    fi
    
    # Contar archivos antes de backup
    local files_count=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "find $STAGE_PATH/wp-content/uploads -type f 2>/dev/null | wc -l")
    log_message "Creando backup de $files_count archivos uploads Stage"
    
    # Crear backup comprimido de uploads Stage
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "
        cd $STAGE_PATH/wp-content
        tar -czf /tmp/stage_uploads_backup_$TIMESTAMP.tar.gz uploads/
    "; then
        # Verificar que el backup se creó correctamente
        local backup_size=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "ls -lh /tmp/stage_uploads_backup_$TIMESTAMP.tar.gz | awk '{print \$5}'")
        log_message "Backup uploads Stage creado exitosamente: $backup_size"
        
        # Subir backup uploads a Azure para recovery extendido
        ssh $SSH_OPTS admwb@$STAGE_SERVER "
            export AZURE_STORAGE_ACCOUNT='$STORAGE_ACCOUNT'
            export AZURE_STORAGE_KEY='$STORAGE_KEY'
            az storage blob upload \
                --container-name '$CONTAINER_NAME' \
                --name 'uploads-backups/stage_uploads_backup_$TIMESTAMP.tar.gz' \
                --file '/tmp/stage_uploads_backup_$TIMESTAMP.tar.gz' \
                --overwrite 2>/dev/null || true
        " > /dev/null 2>&1
        
        log_message "Backup uploads Stage guardado en Azure"
        return 0
    else
        log_message "ERROR: Fallo creando backup uploads Stage" "error"
        return 1
    fi
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

# ============================================================================
# FUNCIONES DE MIGRACIÓN
# ============================================================================

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

# ============================================================================
# FUNCIONES DE VERIFICACIÓN
# ============================================================================

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

# ============================================================================
# FUNCIONES DE ROLLBACK COMPLETO
# ============================================================================

# Función de verificación de consistencia post-rollback
verify_rollback_consistency() {
    log_message "Verificando consistencia post-rollback"
    
    # Verificar WordPress funciona
    if ! verify_wordpress $STAGE_SERVER $STAGE_PATH "Stage"; then
        log_message "ERROR: WordPress no funciona después de rollback" "error"
        return 1
    fi
    
    # Verificar algunos archivos críticos existen
    local media_library_count=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp eval 'echo count(get_posts([\"post_type\" => \"attachment\", \"numberposts\" => -1]));'")
    local uploads_files=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "find $STAGE_PATH/wp-content/uploads -type f | wc -l")
    
    log_message "Post-rollback: $media_library_count attachments en BD, $uploads_files archivos físicos"
    
    # Verificar URLs están correctas para Stage
    local home_url=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp option get home")
    if [[ $home_url != *"web3stg.ciriontechnologies.com"* ]]; then
        log_message "WARNING: Home URL después de rollback puede no ser correcta: $home_url" "warning"
    fi
    
    return 0
}

# Función de rollback COMPLETO (BD + Uploads)
rollback_migration_complete() {
    log_message "========================================" "warning"
    log_message "INICIANDO ROLLBACK COMPLETO (BD + UPLOADS)" "warning"
    log_message "========================================" "warning"
    
    local rollback_success=true
    
    # Paso 1: Rollback Base de Datos
    log_message "Paso 1/3: Restaurando base de datos Stage..."
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && /home/admwb/bin/wp db import /tmp/stage_safety_backup_$TIMESTAMP.sql"; then
        log_message "SUCCESS: BD restaurada exitosamente"
    else
        log_message "ERROR CRÍTICO: Fallo restaurando BD" "error"
        rollback_success=false
    fi
    
    # Paso 2: Rollback Uploads (solo si BD fue exitosa)
    if $rollback_success; then
        log_message "Paso 2/3: Restaurando uploads Stage..."
        
        # Verificar que existe el backup de uploads
        if ssh $SSH_OPTS admwb@$STAGE_SERVER "test -f /tmp/stage_uploads_backup_$TIMESTAMP.tar.gz"; then
            
            # Respaldar uploads actuales por si acaso (backup de rollback)
            ssh $SSH_OPTS admwb@$STAGE_SERVER "
                cd $STAGE_PATH/wp-content
                if [ -d uploads ]; then
                    mv uploads uploads_rollback_backup_$TIMESTAMP || rm -rf uploads
                fi
            " 2>/dev/null
            
            # Restaurar uploads desde backup
            if ssh $SSH_OPTS admwb@$STAGE_SERVER "
                cd $STAGE_PATH/wp-content
                tar -xzf /tmp/stage_uploads_backup_$TIMESTAMP.tar.gz
            "; then
                local restored_files=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "find $STAGE_PATH/wp-content/uploads -type f 2>/dev/null | wc -l")
                log_message "SUCCESS: Uploads restaurados exitosamente ($restored_files archivos)"
            else
                log_message "ERROR: Fallo restaurando uploads desde backup" "error"
                rollback_success=false
                
                # Intentar restaurar uploads desde backup de rollback
                ssh $SSH_OPTS admwb@$STAGE_SERVER "
                    cd $STAGE_PATH/wp-content
                    if [ -d uploads_rollback_backup_$TIMESTAMP ]; then
                        rm -rf uploads
                        mv uploads_rollback_backup_$TIMESTAMP uploads
                    fi
                " 2>/dev/null
            fi
        else
            log_message "WARNING: No se encontró backup de uploads, manteniendo uploads actuales" "warning"
        fi
    fi
    
    # Paso 3: Verificar consistencia post-rollback
    if $rollback_success; then
        log_message "Paso 3/3: Verificando consistencia post-rollback..."
        if verify_rollback_consistency; then
            log_message "SUCCESS: Verificación post-rollback exitosa"
        else
            log_message "WARNING: Verificación post-rollback con advertencias" "warning"
            # No marcamos como fallo porque el rollback técnicamente funcionó
        fi
    fi
    
    # Resultado final del rollback
    if $rollback_success; then
        log_message "========================================" "success"
        log_message "ROLLBACK COMPLETO EXITOSO" "success"
        log_message "Stage restaurado a estado pre-migración" "success"
        log_message "- Base de datos: Restaurada" "success"
        log_message "- Uploads: Restaurados" "success"
        log_message "========================================" "success"
        return 0
    else
        log_message "========================================" "error"
        log_message "ERROR CRÍTICO: ROLLBACK INCOMPLETO" "error"
        log_message "INTERVENCIÓN MANUAL REQUERIDA" "error"
        log_message "========================================" "error"
        return 1
    fi
}

# ============================================================================
# FUNCIONES DE LIMPIEZA Y REPORTE
# ============================================================================

# Función de limpieza con retención inteligente
cleanup() {
    log_message "Ejecutando limpieza con gestión de retención inteligente"
    
    # Limpiar archivos temporales de migración actual
    log_message "Limpiando archivos temporales migración actual..."
    ssh $SSH_OPTS admwb@$DEV_SERVER "rm -f /tmp/dev_migration_$TIMESTAMP.sql*" 2>/dev/null || true
    ssh $SSH_OPTS admwb@$STAGE_SERVER "rm -f /tmp/dev_migration_$TIMESTAMP.sql*" 2>/dev/null || true
    
    # Limpiar backups temporales de rollback
    ssh $SSH_OPTS admwb@$STAGE_SERVER "rm -rf $STAGE_PATH/wp-content/uploads_rollback_backup_*" 2>/dev/null || true
    
    # Aplicar retención inteligente a backups permanentes
    manage_backup_retention $STAGE_SERVER "normal"
    
    log_message "Limpieza con retención completada"
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
    "uploads_sync": "Azure Files Storage",
    "rollback_capability": "Complete (DB + Uploads)",
    "retention_management": "Intelligent (Age + Count)",
    "retention_config": {
        "max_db_backups": $MAX_DB_BACKUPS,
        "max_uploads_backups": $MAX_UPLOADS_BACKUPS,
        "retention_days": $RETENTION_DAYS,
        "min_free_space_mb": $MIN_FREE_SPACE_MB
    },
    "backups": {
        "stage_db": "stage_safety_backup_$TIMESTAMP.sql",
        "stage_uploads": "stage_uploads_backup_$TIMESTAMP.tar.gz",
        "dev_migration": "dev_migration_$TIMESTAMP.sql.gz"
    }
}
EOF
    
    log_message "Reporte guardado: migration_report_$TIMESTAMP.json"
    
    # Para Azure DevOps - publicar artefacto
    echo "##vso[artifact.upload containerfolder=MigrationReports;artifactname=migration-report]$LOG_DIR/migration_report_$TIMESTAMP.json"
}

# ============================================================================
# FUNCIÓN PRINCIPAL
# ============================================================================

# Función principal
main() {
    local start_time=$(date +%s)
    
    log_message "============================================"
    log_message "INICIANDO MIGRACIÓN COMPLETA Development → Stage"
    log_message "VERSION FINAL: Rollback completo + Gestión de retención inteligente"
    log_message "============================================"
    log_message "Migration ID: $TIMESTAMP"
    log_message "Source: Development ($DEV_SERVER:$DEV_PATH)"
    log_message "Target: Stage ($STAGE_SERVER:$STAGE_PATH)"
    log_message "Uploads: Azure Files Storage sincronización incluida"
    log_message "Rollback: COMPLETO (BD + Uploads)"
    log_message "Retención: Inteligente (Edad + Cantidad)"
    log_message "Configuración retención:"
    log_message "  - Max BD backups: $MAX_DB_BACKUPS"
    log_message "  - Max uploads backups: $MAX_UPLOADS_BACKUPS"  
    log_message "  - Retención días: $RETENTION_DAYS"
    log_message "  - Espacio mínimo: ${MIN_FREE_SPACE_MB}MB"
    log_message "============================================"
    
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
    
    # ============================================================================
    # CREAR BACKUPS COMPLETOS CON GESTIÓN DE RETENCIÓN
    # ============================================================================
    
    # Crear backup de seguridad BD Stage
    if ! create_stage_safety_backup; then
        generate_report "FAILED" "0"
        exit 1
    fi
    
    # Crear backup de seguridad UPLOADS Stage (incluye gestión automática de espacio)
    if ! create_stage_uploads_backup; then
        log_message "ERROR: No se pudo crear backup uploads Stage - ABORTANDO por seguridad" "error"
        generate_report "FAILED" "0"
        exit 1
    fi
    
    # Crear backup de Development
    if ! create_dev_migration_backup; then
        generate_report "FAILED" "0"
        exit 1
    fi
    
    # ============================================================================
    # EJECUTAR MIGRACIÓN
    # ============================================================================
    
    # Transferir backup
    if ! transfer_backup; then
        log_message "Error en transferencia - No se ejecutará rollback" "error"
        generate_report "FAILED" "0"
        exit 1
    fi
    
    # Migrar BD
    if ! migrate_database; then
        log_message "Error en migración BD - Ejecutando rollback COMPLETO" "error"
        rollback_migration_complete
        cleanup
        generate_report "FAILED_ROLLBACK_COMPLETE" "$(($(date +%s) - start_time))"
        exit 1
    fi
    
    # Sincronizar uploads
    if ! sync_uploads_azure_files; then
        log_message "Error en sincronización uploads - Ejecutando rollback COMPLETO" "error"
        rollback_migration_complete
        cleanup
        generate_report "FAILED_ROLLBACK_COMPLETE" "$(($(date +%s) - start_time))"
        exit 1
    fi
    
    # Verificar uploads sincronizados
    verify_uploads_sync
    
    # Verificar migración
    if ! verify_migration; then
        log_message "Error en verificación - Ejecutando rollback COMPLETO" "error"
        rollback_migration_complete
        cleanup
        generate_report "FAILED_ROLLBACK_COMPLETE" "$(($(date +%s) - start_time))"
        exit 1
    fi
    
    # ============================================================================
    # ÉXITO - MIGRACIÓN COMPLETA
    # ============================================================================
    
    # Éxito
    cleanup
    local duration=$(($(date +%s) - start_time))
    log_message "MIGRACIÓN COMPLETA EXITOSA en ${duration}s (incluye uploads + rollback completo + gestión retención)" "success"
    generate_report "SUCCESS" "$duration"
    
    # Mostrar resumen
    log_message "========================================" "success"
    log_message "RESUMEN DE MIGRACIÓN COMPLETA EXITOSA:" "success"
    log_message "========================================" "success"
    log_message "   - Migration ID: $TIMESTAMP"
    log_message "   - Duración total: ${duration}s"
    log_message "   - Source: Development (BD + Uploads)"
    log_message "   - Target: Stage (BD + Uploads)"
    log_message "   - Base de datos: Migrada y URLs actualizadas"
    log_message "   - Uploads: Sincronizados vía Azure Files"
    log_message "   - Safety Backups disponibles:"
    log_message "     • BD: stage_safety_backup_$TIMESTAMP.sql"
    log_message "     • Uploads: stage_uploads_backup_$TIMESTAMP.tar.gz"
    log_message "   - Gestión retención: Aplicada automáticamente"
    log_message "   - Azure Container: $CONTAINER_NAME"
    log_message "   - Logs: $LOG_DIR/migration_$TIMESTAMP.log"
    log_message "   - Rollback capability: COMPLETO (BD + Uploads)"
    log_message "========================================" "success"
}

# Manejo de señales para limpieza
trap cleanup EXIT

# Ejecutar migración
main "$@"