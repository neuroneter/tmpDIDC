#!/bin/bash
# migrate-dev-to-stage.sh - Migración Development → Stage para Azure DevOps Pipeline

# Variables de configuración
DEV_SERVER="172.16.4.4"
STAGE_SERVER="172.16.5.4"
DEV_PATH="/var/www/html/webcirion"
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
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp db export /tmp/stage_safety_backup_$TIMESTAMP.sql"; then
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
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && zcat /tmp/dev_migration_$TIMESTAMP.sql.gz | wp db import -"; then
        log_message "Base de datos importada en Stage"
    else
        log_message "Error importando base de datos" "error"
        return 1
    fi
    
    # Actualizar URLs para Stage
    log_message "Actualizando URLs Development → Stage"
    
    # Primero hacer dry-run para ver qué va a cambiar
    log_message "Analizando cambios de URL..."
    ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp search-replace 'dev.website.local' 'web3stg.ciriontechnologies.com' --dry-run --format=table" > /tmp/url_changes_$TIMESTAMP.log
    
    # Mostrar resumen de cambios
    local changes_count=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp search-replace 'dev.website.local' 'web3stg.ciriontechnologies.com' --dry-run --format=count")
    log_message "Se encontraron $changes_count URLs para actualizar"
    
    # Ejecutar search-replace real
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp search-replace 'dev.website.local' 'web3stg.ciriontechnologies.com' --skip-columns=guid"; then
        log_message "URLs actualizadas: dev.website.local → web3stg.ciriontechnologies.com"
    else
        log_message "Error actualizando URLs" "error"
        return 1
    fi
    
    # Buscar URLs con protocolo específico por si hay hardcoded
    log_message "Buscando URLs con protocolo específico..."
    
    # HTTP
    local http_changes=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp search-replace 'http://dev.website.local' 'https://web3stg.ciriontechnologies.com' --dry-run --format=count")
    if [ "$http_changes" -gt 0 ]; then
        ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp search-replace 'http://dev.website.local' 'https://web3stg.ciriontechnologies.com' --skip-columns=guid"
        log_message "URLs HTTP actualizadas: $http_changes cambios"
    fi
    
    # HTTPS
    local https_changes=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp search-replace 'https://dev.website.local' 'https://web3stg.ciriontechnologies.com' --dry-run --format=count")
    if [ "$https_changes" -gt 0 ]; then
        ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp search-replace 'https://dev.website.local' 'https://web3stg.ciriontechnologies.com' --skip-columns=guid"
        log_message "URLs HTTPS actualizadas: $https_changes cambios"
    fi
    
    # Actualizar opciones principales de WordPress
    log_message "Actualizando opciones principales de WordPress"
    ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp option update home 'https://web3stg.ciriontechnologies.com'"
    ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp option update siteurl 'https://web3stg.ciriontechnologies.com'"
    
    # Limpiar cache
    ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp cache flush" > /dev/null 2>&1 || true
    
    # Limpiar rewrite rules
    ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp rewrite flush" > /dev/null 2>&1 || true
    
    log_message "Migración de URLs completada"
    return 0
}

# Función de verificación post-migración
verify_migration() {
    log_message "Verificando migración"
    
    # Verificar WordPress funciona
    if ! verify_wordpress $STAGE_SERVER $STAGE_PATH "Stage"; then
        return 1
    fi
    
    # Verificar BD
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp db check" > /dev/null 2>&1; then
        log_message "Base de datos Stage verificada"
    else
        log_message "Advertencia: No se pudo verificar BD completamente" "warning"
    fi
    
    # Verificar URLs
    local home_url=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp option get home")
    local site_url=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp option get siteurl")
    
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
    local post_count=$(ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp post list --post_status=publish --format=count")
    log_message "Posts verificados: $post_count publicados"
    
    return 0
}

# Función de rollback
rollback_migration() {
    log_message "Iniciando rollback de migración" "warning"
    
    if ssh $SSH_OPTS admwb@$STAGE_SERVER "cd $STAGE_PATH && wp db import /tmp/stage_safety_backup_$TIMESTAMP.sql"; then
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
    "azure_container": "$CONTAINER_NAME"
}
EOF
    
    log_message "Reporte guardado: migration_report_$TIMESTAMP.json"
    
    # Para Azure DevOps - publicar artefacto
    echo "##vso[artifact.upload containerfolder=MigrationReports;artifactname=migration-report]$LOG_DIR/migration_report_$TIMESTAMP.json"
}

# Función principal
main() {
    local start_time=$(date +%s)
    
    log_message "Iniciando migración Development → Stage"
    log_message "Migration ID: $TIMESTAMP"
    log_message "Source: Development ($DEV_SERVER:$DEV_PATH)"
    log_message "Target: Stage ($STAGE_SERVER:$STAGE_PATH)"
    
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
        log_message "Error en migración - Ejecutando rollback" "error"
        rollback_migration
        cleanup
        generate_report "FAILED_ROLLBACK" "$(($(date +%s) - start_time))"
        exit 1
    fi
    
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
    log_message "Migración completada exitosamente en ${duration}s" "success"
    generate_report "SUCCESS" "$duration"
    
    # Mostrar resumen
    log_message "Resumen de migración:"
    log_message "   - ID: $TIMESTAMP"
    log_message "   - Duración: ${duration}s"
    log_message "   - Source: Development"
    log_message "   - Target: Stage"
    log_message "   - Safety Backup: stage_safety_backup_$TIMESTAMP.sql"
    log_message "   - Azure Container: $CONTAINER_NAME"
    log_message "   - Logs: $LOG_DIR/migration_$TIMESTAMP.log"
}

# Manejo de señales para limpieza
trap cleanup EXIT

# Ejecutar migración
main "$@"