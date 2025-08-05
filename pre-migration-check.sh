#!/bin/bash
# pre-migration-check.sh - Verificaciones antes de migracion

DEV_SERVER="172.16.4.4"
STAGE_SERVER="172.16.5.4"
DEV_PATH="/var/www/html/debweb"
STAGE_PATH="/var/www/html/webcirion"
PASSWORD="Cirion#617"

echo "Ejecutando verificaciones pre-migracion"

# Verificar Development
echo "Verificando Development..."
if plink -ssh -pw "$PASSWORD" -batch admwb@$DEV_SERVER "cd $DEV_PATH && wp core is-installed && wp db check" > /dev/null 2>&1; then
    echo "Development OK"
else
    echo "Development tiene problemas"
    exit 1
fi

# Verificar Stage
echo "Verificando Stage..."
if plink -ssh -pw "$PASSWORD" -batch admwb@$STAGE_SERVER "cd $STAGE_PATH && wp core is-installed && wp db check" > /dev/null 2>&1; then
    echo "Stage OK"
else
    echo "Stage tiene problemas" 
    exit 1
fi

# Verificar espacio en disco
echo "Verificando espacio en disco..."
dev_space=$(plink -ssh -pw "$PASSWORD" -batch admwb@$DEV_SERVER "df /tmp | tail -1 | awk '{print \$4}'" 2>/dev/null)
stage_space=$(plink -ssh -pw "$PASSWORD" -batch admwb@$STAGE_SERVER "df /tmp | tail -1 | awk '{print \$4}'" 2>/dev/null)

if [ -z "$dev_space" ] || [ -z "$stage_space" ]; then
    echo "No se pudo verificar espacio en disco"
    exit 1
fi

if [ $dev_space -lt 1000000 ] || [ $stage_space -lt 1000000 ]; then
    echo "Espacio insuficiente en disco"
    exit 1
else
    echo "Espacio en disco suficiente"
fi

echo "Todas las verificaciones pasaron - Listo para migracion"