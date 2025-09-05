#!/bin/bash

# Script: sync_bidireccional.sh
# Descripción: Sincronización bidireccional entre directorio local y pCloud
# Uso: 
#   Subir: ./sync_bidireccional.sh --subir [--delete] [--dry-run] [--item elemento] [--yes] [--overwrite]
#   Bajar: ./sync_bidireccional.sh --bajar [--delete] [--dry-run] [--item elemento] [--yes] [--backup-dir] [--overwrite]

# Configuración - EDITAR ESTAS RUTAS SEGÚN TU CASO
PCLOUD_MOUNT_POINT="${HOME}/pCloudDrive"  # Punto de montaje de pCloud

LOCAL_DIR="${HOME}"  # Directorio local
PCLOUD_BACKUP_COMUN="${PCLOUD_MOUNT_POINT}/Backups/Backup_Comun"  # Directorio de pCloud (modo normal)
PCLOUD_BACKUP_READONLY="${PCLOUD_MOUNT_POINT}/pCloud Backup/feynman.sobremesa.dnf"  # Directorio de pCloud (solo lectura)

# Determinar el directorio donde se encuentra este script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Obtener el hostname de la máquina
HOSTNAME=$(hostname)

# Hostname de rtva
HOSTNAME_RTVA="feynman.rtva.dnf"

# Archivos de configuración (buscar en el directorio del script primero, luego en el directorio actual)
LISTA_SINCRONIZACION=""
EXCLUSIONES=""
LOG_FILE="$HOME/sync_bidireccional.log"

# Archivo para almacenar información de enlaces simbólicos
SYMLINKS_FILE=".sync_bidireccional_symlinks.meta"  

# Variables de control
MODO=""
DRY_RUN=0
DELETE=0
ITEM_ESPECIFICO=""
YES=0
OVERWRITE=0  # Por defecto: no sobrescribir (usar --update)
BACKUP_DIR_MODE="comun"  # Por defecto: Backup_Comun

# Definir códigos de color
# uso: echo -e "${RED}cuerpo del texto.${NC}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color (reset)

# Función para determinar el directorio de pCloud según el modo
get_pcloud_dir() {
    if [ "$BACKUP_DIR_MODE" = "readonly" ]; then
        echo "$PCLOUD_BACKUP_READONLY"
    else
        echo "$PCLOUD_BACKUP_COMUN"
    fi
}

# Buscar archivos de configuración
find_config_files() {
    # Determinar el nombre del archivo de lista según el hostname
    local lista_por_defecto="sync_bidireccional_directorios.ini"
    local lista_especifica="sync_bidireccional_directorios_${HOSTNAME_RTVA}.ini"
    
    # Si el hostname es "${HOSTNAME_RTVA}", usar el archivo específico
    if [ "$HOSTNAME" = "${HOSTNAME_RTVA}" ]; then
        
        # Primero buscar en el directorio del script
        if [ -f "${SCRIPT_DIR}/${lista_especifica}" ]; then
            LISTA_SINCRONIZACION="${SCRIPT_DIR}/${lista_especifica}"
        elif [ -f "./${lista_especifica}" ]; then
            # Si no está en el directorio del script, buscar en el directorio actual
            LISTA_SINCRONIZACION="./${lista_especifica}"
        else
            echo "ERROR: No se encontró el archivo de lista específico '${lista_especifica}'"
            echo "Busca en:"
            echo "  - ${SCRIPT_DIR}/"
            echo "  - $(pwd)/"
            exit 1
        fi
    else
        # Para otros hostnames, usar el archivo por defecto
        
        # Primero buscar en el directorio del script
        if [ -f "${SCRIPT_DIR}/${lista_por_defecto}" ]; then
            LISTA_SINCRONIZACION="${SCRIPT_DIR}/${lista_por_defecto}"
        elif [ -f "./${lista_por_defecto}" ]; then
            # Si no está en el directorio del script, buscar en el directorio actual
            LISTA_SINCRONIZACION="./${lista_por_defecto}"
        fi
    fi
    
    # Buscar archivo de exclusiones (igual para todos los hosts)
    if [ -f "${SCRIPT_DIR}/sync_bidireccional_exclusiones.ini" ]; then
        EXCLUSIONES="${SCRIPT_DIR}/sync_bidireccional_exclusiones.ini"
    elif [ -f "./sync_bidireccional_exclusiones.ini" ]; then
        EXCLUSIONES="./sync_bidireccional_exclusiones.ini"
    fi
}

# Llamar a la función para buscar archivos de configuración
find_config_files

# Función para mostrar ayuda
mostrar_ayuda() {
    echo "Uso: $0 [OPCIONES]"
    echo ""
    echo "Opciones PRINCIPALES (obligatorio una de ellas):"
    echo "  --subir           Sincroniza desde el directorio local a pCloud (${LOCAL_DIR} → pCloud)"
    echo "  --bajar           Sincroniza desde pCloud al directorio local (pCloud → ${LOCAL_DIR})"
    echo ""
    echo "Opciones SECUNDARIAS (opcionales):"
    echo "  --delete          Elimina en destino los archivos que no existan en origen (delete-delay)"
    echo "  --dry-run         Simula la operación sin hacer cambios reales"
    echo "  --item ELEMENTO   Sincroniza solo el elemento especificado (archivo o directorio)"
    echo "  --yes             No pregunta confirmación, ejecuta directamente"
    echo "  --backup-dir      Usa el directorio de backup de solo lectura (pCloud Backup) en lugar de Backup_Comun"
    echo "  --overwrite       Sobrescribe todos los archivos en destino (no usa --update)"
    echo "  --help            Muestra esta ayuda"
    echo ""
    echo "Archivos de configuración:"
    echo "  - Directorio del script: ${SCRIPT_DIR}/"
    echo "  - Directorio actual: $(pwd)/"
    
    if [ "$HOSTNAME" = "${HOSTNAME_RTVA}" ]; then
        echo "  - Busca: sync_bidireccional_directorios_${HOSTNAME_RTVA}.ini (específico para este host)"
    else
        echo "  - Busca: sync_bidireccional_directorios.ini (por defecto)"
    fi
    
    echo "  - Busca: sync_bidireccional_exclusiones.ini"
    echo ""
    echo "Hostname detectado: ${HOSTNAME}"
    echo ""
    echo "Ejemplos:"
    echo "  ./sync_bidireccional.sh --subir"
    echo "  ./sync_bidireccional.sh --bajar --dry-run"
    echo "  ./sync_bidireccional.sh --subir --delete --yes"
    echo "  ./sync_bidireccional.sh --subir --item documentos/"
    echo "  ./sync_bidireccional.sh --bajar --item configuracion.ini --dry-run"
    echo "  ./sync_bidireccional.sh --bajar --backup-dir --yes"
    echo "  ./sync_bidireccional.sh --bajar --backup-dir --item documentos/ --yes"
    echo "  ./sync_bidireccional.sh --subir --overwrite  # Sobrescribe todos los archivos"
}

# Función para verificar si pCloud está montado
verificar_pcloud_montado() {
    local PCLOUD_DIR=$(get_pcloud_dir)
    
    # Verificar si el punto de montaje de pCloud existe
    if [ ! -d "$PCLOUD_MOUNT_POINT" ]; then
        echo "ERROR: El punto de montaje de pCloud no existe: $PCLOUD_MOUNT_POINT"
        echo "Asegúrate de que pCloud Drive esté instalado y ejecutándose."
        exit 1
    fi
    
    # Verificación más robusta: comprobar si pCloud está realmente montado
    # 1. Verificar si el directorio está vacío (puede indicar que no está montado)
    if [ -z "$(ls -A "$PCLOUD_MOUNT_POINT" 2>/dev/null)" ]; then
        echo "ERROR: El directorio de pCloud está vacío: $PCLOUD_MOUNT_POINT"
        echo "Esto sugiere que pCloud Drive no está montado correctamente."
        exit 1
    fi
    
    # 2. Verificar usando el comando mount
    if ! mount | grep -q "pCloud\|pcloud"; then
        echo "ERROR: pCloud no aparece en la lista de sistemas de archivos montados"
        echo "Asegúrate de que pCloud Drive esté ejecutándose y montado."
        exit 1
    fi
    
    # Verificar si el directorio específico de pCloud existe
    if [ ! -d "$PCLOUD_DIR" ]; then
        echo "ERROR: El directorio de pCloud no existe: $PCLOUD_DIR"
        echo "Asegúrate de que:"
        echo "1. pCloud Drive esté ejecutándose"
        echo "2. Tu cuenta de pCloud esté sincronizada"
        echo "3. El directorio exista en tu pCloud"
        exit 1
    fi
    
    # Verificación adicional: intentar escribir en el directorio (solo si no es dry-run y no es modo backup-dir)
    if [ $DRY_RUN -eq 0 ] && [ "$BACKUP_DIR_MODE" = "comun" ]; then
        local test_file="${PCLOUD_DIR}/.test_write_$$"
        if touch "$test_file" 2>/dev/null; then
            rm -f "$test_file"
        else
            echo "ERROR: No se puede escribir en el directorio de pCloud: $PCLOUD_DIR"
            echo "Asegúrate de que pCloud Drive esté funcionando correctamente y tengas permisos de escritura."
            exit 1
        fi
    fi
    
    echo "✓ Verificación de pCloud: OK - El directorio está montado y accesible"
}

# Función para mostrar el banner informativo
mostrar_banner() {
    local PCLOUD_DIR=$(get_pcloud_dir)
    
    echo "=========================================="
    
    if [ "$MODO" = "subir" ]; then
        echo "MODO: SUBIR (Local → pCloud)"
        echo "ORIGEN: ${LOCAL_DIR}"
        echo "DESTINO: ${PCLOUD_DIR}"
    else
        echo "MODO: BAJAR (pCloud → Local)"
        echo "ORIGEN: ${PCLOUD_DIR}"
        echo "DESTINO: ${LOCAL_DIR}"
    fi
    
    if [ "$BACKUP_DIR_MODE" = "readonly" ]; then
        echo "DIRECTORIO: Backup de solo lectura (pCloud Backup)"
    else
        echo "DIRECTORIO: Backup común (Backup_Comun)"
    fi
    
    if [ $DRY_RUN -eq 1 ]; then
        echo -e "ESTADO: ${GREEN}MODO SIMULACIÓN${NC} (no se realizarán cambios)"
    fi
    
    if [ $DELETE -eq 1 ]; then
        echo -e "BORRADO: ${GREEN}ACTIVADO${NC} (se eliminarán archivos obsoletos)"
    fi
    
    if [ $YES -eq 1 ]; then
        echo "CONFIRMACIÓN: Automática (sin preguntar)"
    fi
    
    if [ $OVERWRITE -eq 1 ]; then
        echo -e "SOBRESCRITURA: ${GREEN}ACTIVADA${NC} (se sobrescribirán todos los archivos)"
    else
        echo "MODO: SEGURO (--update activado, se preservan archivos más recientes en destino)"
    fi
    
    if [ -n "$ITEM_ESPECIFICO" ]; then
        echo "ELEMENTO ESPECÍFICO: $ITEM_ESPECIFICO"
    else
        echo "LISTA: ${LISTA_SINCRONIZACION:-No encontrada}"
    fi
    
    echo "EXCLUSIONES: ${EXCLUSIONES:-No encontradas}"
    echo "=========================================="
}

# Función para confirmar la ejecución
confirmar_ejecucion() {
    if [ $YES -eq 1 ]; then
        echo "Confirmación automática (--yes): se procede con la sincronización"
        return
    fi
    
    echo ""
    read -p "¿Desea continuar con la sincronización? [s/N]: " respuesta
    if [ "$respuesta" != "s" ] && [ "$respuesta" != "S" ]; then
        echo "Operación cancelada por el usuario."
        exit 0
    fi
    echo ""
}

# Función para verificar y crear archivo de log
inicializar_log() {
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
    echo "==========================================" >> "$LOG_FILE"
    echo "Sincronización iniciada: $(date)" >> "$LOG_FILE"
    echo "Modo: $MODO" >> "$LOG_FILE"
    echo "Delete: $DELETE" >> "$LOG_FILE"
    echo "Dry-run: $DRY_RUN" >> "$LOG_FILE"
    echo "Backup-dir: $BACKUP_DIR_MODE" >> "$LOG_FILE"
    echo "Overwrite: $OVERWRITE" >> "$LOG_FILE"
    if [ -n "$ITEM_ESPECIFICO" ]; then
        echo "Item específico: $ITEM_ESPECIFICO" >> "$LOG_FILE"
    fi
    echo "Lista sincronización: ${LISTA_SINCRONIZACION:-No encontrada}" >> "$LOG_FILE"
    echo "Exclusiones: ${EXCLUSIONES:-No encontradas}" >> "$LOG_FILE"
}

# Función para registrar en log
registrar_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Función para verificar dependencias
verificar_dependencias() {
    if ! command -v rsync &> /dev/null; then
        echo "ERROR: rsync no está instalado. Instálalo con:"
        echo "sudo apt install rsync  # Debian/Ubuntu"
        echo "sudo dnf install rsync  # RedHat/CentOS"
        exit 1
    fi
}

# Función para verificar archivos de configuración
verificar_archivos_configuracion() {
    if [ -z "$ITEM_ESPECIFICO" ] && [ -z "$LISTA_SINCRONIZACION" ]; then
        echo "ERROR: No se encontró el archivo de lista 'sync_bidireccional_directorios.ini'"
        echo "Busca en:"
        echo "  - ${SCRIPT_DIR}/"
        echo "  - $(pwd)/"
        echo "O crea un archivo con la lista de rutas a sincronizar o usa --item"
        exit 1
    fi
    
    if [ -z "$EXCLUSIONES" ]; then
        echo "ADVERTENCIA: No se encontró el archivo de exclusiones 'sync_bidireccional_exclusiones.ini'"
        echo "No se aplicarán exclusiones específicas"
    fi
}

# Función para generar archivo de enlaces
generar_archivo_enlaces() {
    local archivo_enlaces="$1"
    > "$archivo_enlaces"  # Limpiar archivo existente

    if [ -n "$ITEM_ESPECIFICO" ]; then
        procesar_elemento_para_enlaces "$ITEM_ESPECIFICO" "$archivo_enlaces"
    else
        while IFS= read -r elemento; do
            [[ -n "$elemento" && ! "$elemento" =~ ^[[:space:]]*# ]] &&
            procesar_elemento_para_enlaces "$elemento" "$archivo_enlaces"
        done < "$LISTA_SINCRONIZACION"
    fi
}

# Función auxiliar para procesar elementos
procesar_elemento_para_enlaces() {
    local elemento="$1"
    local archivo_enlaces="$2"
    local ruta_completa="${LOCAL_DIR}/${elemento}"

    [ ! -e "$ruta_completa" ] && return

    if [ -d "$ruta_completa" ]; then
        find "$ruta_completa" -type l -print0 | while IFS= read -r -d '' enlace; do
            registrar_enlace "$enlace" "$archivo_enlaces"
        done
    elif [ -L "$ruta_completa" ]; then
        registrar_enlace "$ruta_completa" "$archivo_enlaces"
    fi
}

# Función para registrar enlace
registrar_enlace() {
    local enlace="$1"
    local archivo_enlaces="$2"
    local ruta_relativa=$(realpath --relative-to="${LOCAL_DIR}" "$enlace")
    local destino=$(readlink "$enlace")
    
    echo -e "${ruta_relativa}\t${destino}" >> "$archivo_enlaces"
}

# Función para recrear enlaces
recrear_enlaces_desde_archivo() {
    local archivo_enlaces="${LOCAL_DIR}/.symlinks.txt"
    [ ! -f "$archivo_enlaces" ] && return

    while IFS=$'\t' read -r ruta_relativa destino; do
        [ -z "$ruta_relativa" ] && continue
        
        local ruta_completa="${LOCAL_DIR}/${ruta_relativa}"
        local dir_padre=$(dirname "$ruta_completa")
        
        [ ! -d "$dir_padre" ] && mkdir -p "$dir_padre"
        
        if [ $DRY_RUN -eq 1 ]; then
            echo "SIMULACIÓN: ln -sfn '$destino' '$ruta_completa'"
        else
            ln -sfn "$destino" "$ruta_completa" 2>/dev/null || echo "Error creando enlace: $ruta_completa -> $destino"
        fi
    done < "$archivo_enlaces"
}


# Función para construir opciones de rsync
construir_opciones_rsync() {
    #local opciones="-avh --checksum --progress"
    #local opciones="-avh --checksum --progress --whole-file"
    #local opciones="-avl --no-perms --no-owner --no-group --checksum --progress --whole-file" 
    #local opciones="-av --no-perms --no-owner --no-group --checksum --progress --copy-links" 
    #local opciones="-av --no-perms --no-owner --no-group --checksum --progress --whole-file --copy-links" 
    # rsync -rv 
    local opciones="--recursive --verbose --times --checksum --progress --whole-file --no-links" 

 
    # Añadir --update si no estamos en modo sobrescritura
    if [ $OVERWRITE -eq 0 ]; then
        opciones="$opciones --update"
    fi
    
    if [ $DRY_RUN -eq 1 ]; then
        opciones="$opciones --dry-run"
    fi
    
    if [ $DELETE -eq 1 ]; then
        opciones="$opciones --delete-delay"
    fi
    
    # Añadir exclusiones si el archivo existe
    if [ -n "$EXCLUSIONES" ] && [ -f "$EXCLUSIONES" ]; then
        while IFS= read -r linea; do
            # Ignorar líneas vacías y comentarios
            if [[ -n "$linea" && ! "$linea" =~ ^[[:space:]]*# ]]; then
                opciones="$opciones --exclude='$linea'"
            fi
        done < "$EXCLUSIONES"
    fi
    
    echo "$opciones"
}

# Función para sincronizar un elemento
sincronizar_elemento() {
    local elemento="$1"
    local opciones="$2"
    local PCLOUD_DIR=$(get_pcloud_dir)
    
    # Definir origen y destino según el modo
    if [ "$MODO" = "subir" ]; then
        origen="${LOCAL_DIR}/${elemento}"
        destino="${PCLOUD_DIR}/${elemento}"
        direccion="LOCAL → PCLOUD (Subir)"
    else
        origen="${PCLOUD_DIR}/${elemento}"
        destino="${LOCAL_DIR}/${elemento}"
        direccion="PCLOUD → LOCAL (Bajar)"
    fi
    
    # Verificar si el origen existe
    if [ ! -e "$origen" ]; then
        echo "ADVERTENCIA: No existe $origen"
        registrar_log "ADVERTENCIA: No existe $origen"
        return 1
    fi
    
    # Determinar si es directorio or archivo
    if [ -d "$origen" ]; then
        origen="${origen}/"
        # Solo añadir barra al destino si es un directorio
        if [ ! -e "$destino" ] || [ -d "$destino" ]; then
            destino="${destino}/"
        fi
    fi
    
    # Crear directorio de destino si no existe (solo si no estamos en dry-run)
    local dir_destino=$(dirname "$destino")
    if [ ! -d "$dir_destino" ] && [ $DRY_RUN -eq 0 ]; then
        mkdir -p "$dir_destino"
        echo "Directorio creado: $dir_destino"
        registrar_log "Directorio creado: $dir_destino"
    elif [ ! -d "$dir_destino" ] && [ $DRY_RUN -eq 1 ]; then
        echo "SIMULACIÓN: Se crearía directorio: $dir_destino"
        registrar_log "SIMULACIÓN: Se crearía directorio: $dir_destino"
    fi
   
    echo "" 
    echo -e "${BLUE}Sincronizando: $elemento ($direccion)${NC}"
    registrar_log "Sincronizando: $elemento ($direccion)"
    
    # Construir y ejecutar comando
    local comando="rsync $opciones '$origen' '$destino'"
    echo "Comando: $comando"
    registrar_log "Comando ejecutado: $comando"
    
    eval $comando
    local resultado=$?
    
    if [ $resultado -eq 0 ]; then
        echo "✓ Sincronización completada: $elemento"
        registrar_log "Sincronización completada: $elemento"
    else
        echo "✗ Error en sincronización: $elemento (código: $resultado)"
        registrar_log "Error en sincronización: $elemento (código: $resultado)"
    fi
    
    return $resultado
}

# Función principal de sincronización
sincronizar() {
    local opciones=$(construir_opciones_rsync)
    local exit_code=0
    
    mostrar_banner
    
    # Verificar si pCloud está montado antes de continuar
    verificar_pcloud_montado
    
    # Preguntar confirmación antes de continuar (excepto en dry-run o si se usa --yes)
    if [ $DRY_RUN -eq 0 ]; then
        confirmar_ejecucion
    fi
    
    # Si se especificó un elemento específico
    if [ -n "$ITEM_ESPECIFICO" ]; then
        echo "Sincronizando elemento específico: $ITEM_ESPECIFICO"
        sincronizar_elemento "$ITEM_ESPECIFICO" "$opciones"
        exit_code=$?
    else
        # Leer y procesar la lista de sincronización
        echo "Procesando lista de sincronización: ${LISTA_SINCRONIZACION}"
        while IFS= read -r linea; do
            # Ignorar líneas vacías y comentarios
            if [[ -n "$linea" && ! "$linea" =~ ^[[:space:]]*# ]]; then
                sincronizar_elemento "$linea" "$opciones"
                if [ $? -ne 0 ]; then
                    exit_code=1
                fi
                echo "------------------------------------------"
            fi
        done < "$LISTA_SINCRONIZACION"
    fi
    
    # Manejo de enlaces simbólicos
    if [ "$MODO" = "subir" ]; then
        # Generar y subir archivo de enlaces
        local archivo_temporal=$(mktemp)
        generar_archivo_enlaces "$archivo_temporal"
    elif [ "$MODO" = "bajar" ]; then
        # Recrear enlaces desde archivo
        recrear_enlaces_desde_archivo
    fi

    return $exit_code
}

# Ajustar permiso de los ficheros
# FUNCIÓN CORREGIDA PARA AJUSTAR PERMISOS DE EJECUCIÓN
ajustar_permisos_ejecutables() {
    local directorio_base="${LOCAL_DIR}"
    local exit_code=0
    
    echo "Ajustando permisos de ejecución..."
    
    # Procesar cada argumento
    for patron in "$@"; do
        # Determinar el tipo de patrón
        if [[ "$patron" == *"*"* ]]; then
            # Es un patrón con comodín (como *.sh)
            local directorio_patron="${directorio_base}/$(dirname "$patron")"
            local archivo_patron="$(basename "$patron")"
            
            if [ -d "$directorio_patron" ]; then
                echo "Aplicando permisos a: $patron (recursivo)"
                # Usar find para buscar archivos que coincidan con el patrón
                find "$directorio_patron" -name "$archivo_patron" -type f -exec chmod +x {} \;
            else
                echo "Advertencia: El directorio no existe - $directorio_patron"
                exit_code=1
            fi
        else
            # Es una ruta específica
            local ruta_completa="${directorio_base}/${patron}"
            
            # Verificar si la ruta existe
            if [ ! -e "$ruta_completa" ]; then
                echo "Advertencia: La ruta no existe - $ruta_completa"
                exit_code=1
                continue
            fi
            
            if [ -f "$ruta_completa" ]; then
                # Es un archivo específico
                echo "Aplicando permisos a: $patron"
                chmod +x "$ruta_completa"
            elif [ -d "$ruta_completa" ]; then
                # Es un directorio específico - aplicar recursivamente
                echo "Aplicando permisos recursivos a: $patron"
                find "$ruta_completa" -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" -o -name "*.jl" \) -exec chmod +x {} \;
            fi
        fi
    done
    
    #echo "Ajuste de permisos completado."
    return $exit_code
}

# Procesar argumentos
if [ $# -eq 0 ]; then
    echo "ERROR: Debes especificar al menos --subir o --bajar"
    mostrar_ayuda
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --subir)
            if [ -n "$MODO" ]; then
                echo "ERROR: No puedes usar --subir y --bajar simultáneamente"
                mostrar_ayuda
                exit 1
            fi
            MODO="subir"
            shift
            ;;
        --bajar)
            if [ -n "$MODO" ]; then
                echo "ERROR: No puedes usar --subir y --bajar simultáneamente"
                mostrar_ayuda
                exit 1
            fi
            MODO="bajar"
            shift
            ;;
        --delete)
            DELETE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --item)
            if [ $# -lt 2 ]; then
                echo "ERROR: La opción --item requiere un argumento"
                mostrar_ayuda
                exit 1
            fi
            ITEM_ESPECIFICO="$2"
            shift 2
            ;;
        --yes)
            YES=1
            shift
            ;;
        --backup-dir)
            BACKUP_DIR_MODE="readonly"
            shift
            ;;
        --overwrite)
            OVERWRITE=1
            shift
            ;;
        --help)
            mostrar_ayuda
            exit 0
            ;;
        *)
            echo "ERROR: Opción desconocida: $1"
            mostrar_ayuda
            exit 1
            ;;
    esac
done

# Validación principal: debe tener exactamente un modo
if [ -z "$MODO" ]; then
    echo "ERROR: Debes especificar --subir o --bajar"
    mostrar_ayuda
    exit 1
fi

# Ejecutar verificaciones
verificar_dependencias
find_config_files  # Buscar archivos de configuración
verificar_archivos_configuracion
inicializar_log

# Ejecutar sincronización
sincronizar
resultado=$?

# Llamar a la función para ajustar permisos solo en modo --bajar y si no es dry-run
if [ "$MODO" = "bajar" ] && [ $DRY_RUN -eq 0 ]; then
    # Recrear enlaces después de bajar (si es necesario)
    # Ya esta puesto en la función sincronizar, por eso esta comentada
    #recrear_enlaces_desde_archivo


    # Aquí defines los patrones que deseas procesar
    ajustar_permisos_ejecutables \
        ".local/bin/*.sh" \
        ".local/bin/*.bash" \
        ".local/bin/*.py" \
        ".local/bin/pcloud" \
        ".config/dotfiles/*.sh"
elif [ "$MODO" = "bajar" ] && [ $DRY_RUN -eq 1 ]; then
    echo "Modo simulación: Se omitió el ajuste de permisos de ejecución (solo aplica en modo --bajar)"
fi

echo ""
echo "=========================================="
if [ $resultado -eq 0 ]; then
    if [ $DRY_RUN -eq 1 ]; then
        echo "✓ Simulación completada exitosamente"
        registrar_log "Simulación completada exitosamente"
    else
        echo "✓ Sincronización completada exitosamente"
        registrar_log "Sincronización completada exitosamente"
    fi
else
    echo "✗ Sincronización completada con errores"
    registrar_log "Sincronización completada con errores"
fi

echo "Log guardado en: $LOG_FILE"
echo "=========================================="
