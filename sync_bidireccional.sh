#!/bin/bash

# Script: sync_bidireccional.sh
# Descripción: Sincronización bidireccional entre directorio local y pCloud.
#
# Mejoras de esta versión:
# - Se eliminó `eval` por seguridad. Ahora se usa un array para las opciones de rsync.
# - Se añadió 'set -euo pipefail' para un modo de ejecución más estricto y seguro.
# - Lógica de búsqueda de archivos de configuración simplificada.
# - Limpieza automática de archivos temporales garantizada con 'trap'.
# - Estructura mejorada con una función main().

set -euo pipefail # Salir en caso de error, variable no definida o error en pipe

# --- Configuración - EDITAR ESTAS RUTAS SEGÚN TU CASO ---
readonly PCLOUD_MOUNT_POINT="${HOME}/pCloudDrive"  # Punto de montaje de pCloud
readonly LOCAL_DIR="${HOME}"                      # Directorio local
readonly PCLOUD_BACKUP_COMUN="${PCLOUD_MOUNT_POINT}/Backups/Backup_Comun" # Directorio de pCloud (modo normal)
readonly PCLOUD_BACKUP_READONLY="${PCLOUD_MOUNT_POINT}/pCloud Backup/feynman.sobremesa.dnf" # Directorio de pCloud (solo lectura)
# --- Fin de la Configuración ---

# Variables globales
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOSTNAME=$(hostname)
readonly HOSTNAME_RTVA="feynman.rtva.dnf" # Hostname específico

# Archivos de configuración y logs
LISTA_SINCRONIZACION=""
EXCLUSIONES=""
readonly LOG_FILE="${HOME}/sync_bidireccional.log"
readonly SYMLINKS_FILE=".sync_bidireccional_symlinks.meta"

# Variables de control de argumentos
MODO=""
DRY_RUN=0
DELETE=0
ITEM_ESPECIFICO=""
YES=0
OVERWRITE=0
BACKUP_DIR_MODE="comun"

# Opciones para rsync (se llenará en build_rsync_opts)
declare -a RSYNC_OPTS

# Definir códigos de color
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color (reset)

# --- Funciones ---

# Muestra la ayuda del script
mostrar_ayuda() {
    printf "Uso: %s [OPCIONES]\n" "$0"
    printf "\n"
    printf "Opciones PRINCIPALES (obligatorio una de ellas):\n"
    printf "  --subir           Sincroniza desde el directorio local a pCloud (%s → pCloud)\n" "${LOCAL_DIR}"
    printf "  --bajar           Sincroniza desde pCloud al directorio local (pCloud → %s)\n" "${LOCAL_DIR}"
    printf "\n"
    printf "Opciones SECUNDARIAS (opcionales):\n"
    printf "  --delete          Elimina en destino los archivos que no existan en origen (delete-delay)\n"
    printf "  --dry-run         Simula la operación sin hacer cambios reales\n"
    printf "  --item ELEMENTO   Sincroniza solo el elemento especificado (archivo o directorio)\n"
    printf "  --yes             No pregunta confirmación, ejecuta directamente\n"
    printf "  --backup-dir      Usa el directorio de backup de solo lectura (pCloud Backup)\n"
    printf "  --overwrite       Sobrescribe todos los archivos en destino (desactiva --update)\n"
    printf "  --help            Muestra esta ayuda\n"
    printf "\n"
    printf "Archivos de configuración:\n"
    printf "  - Directorio del script: %s/\n" "${SCRIPT_DIR}"
    printf "  - Directorio actual: %s/\n" "$(pwd)"

    if [[ "$HOSTNAME" == "${HOSTNAME_RTVA}" ]]; then
        printf "  - Busca: sync_bidireccional_directorios_%s.ini (específico para este host)\n" "${HOSTNAME_RTVA}"
    else
        printf "  - Busca: sync_bidireccional_directorios.ini (por defecto)\n"
    fi

    printf "  - Busca: sync_bidireccional_exclusiones.ini\n"
    printf "\n"
    printf "Hostname detectado: %s\n" "${HOSTNAME}"
    printf "\n"
    printf "Ejemplos:\n"
    printf "  ./sync_bidireccional.sh --subir\n"
    printf "  ./sync_bidireccional.sh --bajar --dry-run\n"
    printf "  ./sync_bidireccional.sh --subir --delete --yes\n"
    printf "  ./sync_bidireccional.sh --subir --item documentos/\n"
}

# Devuelve la ruta del directorio de pCloud a usar
get_pcloud_dir() {
    if [[ "$BACKUP_DIR_MODE" == "readonly" ]]; then
        echo "$PCLOUD_BACKUP_READONLY"
    else
        echo "$PCLOUD_BACKUP_COMUN"
    fi
}

# Busca los archivos de configuración
find_config_files() {
    local lista_base="sync_bidireccional_directorios"
    local exclusiones_base="sync_bidireccional_exclusiones.ini"
    local lista_filename

    if [[ "$HOSTNAME" == "$HOSTNAME_RTVA" ]]; then
        lista_filename="${lista_base}_${HOSTNAME_RTVA}.ini"
    else
        lista_filename="${lista_base}.ini"
    fi

    # Buscar archivo de lista de sincronización
    if [[ -f "${SCRIPT_DIR}/${lista_filename}" ]]; then
        LISTA_SINCRONIZACION="${SCRIPT_DIR}/${lista_filename}"
    elif [[ -f "./${lista_filename}" ]]; then
        LISTA_SINCRONIZACION="./${lista_filename}"
    fi

    # Buscar archivo de exclusiones
    if [[ -f "${SCRIPT_DIR}/${exclusiones_base}" ]]; then
        EXCLUSIONES="${SCRIPT_DIR}/${exclusiones_base}"
    elif [[ -f "./${exclusiones_base}" ]]; then
        EXCLUSIONES="./${exclusiones_base}"
    fi
}

# Verifica dependencias necesarias
verificar_dependencias() {
    if ! command -v rsync &> /dev/null; then
        printf "${RED}ERROR: rsync no está instalado. Instálalo para continuar.${NC}\n" >&2
        exit 1
    fi
}

# Verifica que pCloud esté montado y accesible
verificar_pcloud_montado() {
    local pcloud_dir
    pcloud_dir=$(get_pcloud_dir)

    if ! mount | grep -q "pCloud\|pcloud"; then
        printf "${RED}ERROR: pCloud no parece estar montado.${NC}\n" >&2
        printf "Asegúrate de que pCloud Drive esté ejecutándose.\n" >&2
        exit 1
    fi

    if [[ ! -d "$pcloud_dir" ]]; then
        printf "${RED}ERROR: El directorio de pCloud no existe: %s${NC}\n" "$pcloud_dir" >&2
        exit 1
    fi

    if [[ $DRY_RUN -eq 0 && "$BACKUP_DIR_MODE" == "comun" ]]; then
        if ! touch "${pcloud_dir}/.test_write_$$" 2>/dev/null; then
            printf "${RED}ERROR: No se puede escribir en el directorio de pCloud: %s${NC}\n" "$pcloud_dir" >&2
            exit 1
        else
            rm -f "${pcloud_dir}/.test_write_$$"
        fi
    fi

    printf "${GREEN}✓ Verificación de pCloud: OK - El directorio está montado y accesible.${NC}\n"
}

# Muestra un resumen de la operación a realizar
mostrar_banner() {
    local pcloud_dir
    pcloud_dir=$(get_pcloud_dir)

    printf "==========================================\n"
    if [[ "$MODO" == "subir" ]]; then
        printf "MODO: SUBIR (Local → pCloud)\n"
        printf "ORIGEN: %s\n" "${LOCAL_DIR}"
        printf "DESTINO: %s\n" "${pcloud_dir}"
    else
        printf "MODO: BAJAR (pCloud → Local)\n"
        printf "ORIGEN: %s\n" "${pcloud_dir}"
        printf "DESTINO: %s\n" "${LOCAL_DIR}"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        printf "ESTADO: ${GREEN}MODO SIMULACIÓN${NC} (no se realizarán cambios)\n"
    fi
    if [[ $DELETE -eq 1 ]]; then
        printf "BORRADO: ${GREEN}ACTIVADO${NC} (se eliminarán archivos obsoletos)\n"
    fi
    if [[ $OVERWRITE -eq 1 ]]; then
        printf "SOBRESCRITURA: ${GREEN}ACTIVADA${NC} (se sobrescribirán todos los archivos)\n"
    else
        printf "MODO: SEGURO (--update activado, se preservan archivos más recientes)\n"
    fi
    if [[ -n "$ITEM_ESPECIFICO" ]]; then
        printf "ELEMENTO ESPECÍFICO: %s\n" "$ITEM_ESPECIFICO"
    else
        printf "LISTA: %s\n" "${LISTA_SINCRONIZACION:-No encontrada}"
    fi
    printf "EXCLUSIONES: %s\n" "${EXCLUSIONES:-No encontradas}"
    printf "==========================================\n"
}

# Pide confirmación al usuario para continuar
confirmar_ejecucion() {
    if [[ $YES -eq 1 || $DRY_RUN -eq 1 ]]; then
        return
    fi

    printf "\n"
    read -p "¿Desea continuar con la sincronización? [s/N]: " respuesta
    if [[ ! "$respuesta" =~ ^[sS]$ ]]; then
        printf "Operación cancelada por el usuario.\n"
        exit 0
    fi
    printf "\n"
}

# Escribe una entrada en el archivo de log
registrar_log() {
    # Inicializa el log si es la primera vez
    if [[ ! -f "$LOG_FILE" ]]; then
        printf "==========================================\n" >> "$LOG_FILE"
        printf "Sincronización iniciada: %s\n" "$(date)" >> "$LOG_FILE"
        printf "Modo: %s\n" "$MODO" >> "$LOG_FILE"
        printf "Item: %s\n" "${ITEM_ESPECIFICO:-Toda la lista}" >> "$LOG_FILE"
        printf -- "----------------------------------------\n" >> "$LOG_FILE"
    fi
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

# Construye el array de opciones para rsync
build_rsync_opts() {
    RSYNC_OPTS=(--recursive --verbose --times --checksum --progress --whole-file --no-links)

    if [[ $OVERWRITE -eq 0 ]]; then
        RSYNC_OPTS+=("--update")
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        RSYNC_OPTS+=("--dry-run")
    fi
    if [[ $DELETE -eq 1 ]]; then
        RSYNC_OPTS+=("--delete-delay")
    fi

    if [[ -n "$EXCLUSIONES" && -f "$EXCLUSIONES" ]]; then
        while IFS= read -r linea || [[ -n "$linea" ]]; do
            if [[ -n "$linea" && ! "$linea" =~ ^[[:space:]]*# ]]; then
                RSYNC_OPTS+=("--exclude=$linea")
            fi
        done < "$EXCLUSIONES"
    fi
}

# Sincroniza un único elemento
sincronizar_elemento() {
    local elemento="$1"
    local pcloud_dir origen destino direccion dir_destino

    pcloud_dir=$(get_pcloud_dir)

    if [[ "$MODO" == "subir" ]]; then
        origen="${LOCAL_DIR}/${elemento}"
        destino="${pcloud_dir}/${elemento}"
        direccion="LOCAL → PCLOUD"
    else
        origen="${pcloud_dir}/${elemento}"
        destino="${LOCAL_DIR}/${elemento}"
        direccion="PCLOUD → LOCAL"
    fi

    if [[ ! -e "$origen" ]]; then
        printf "${YELLOW}ADVERTENCIA: No existe el origen %s${NC}\n" "$origen"
        registrar_log "ADVERTENCIA: No existe el origen ${origen}"
        return
    fi

    # Añadir barra final si el origen es un directorio para copiar su contenido
    if [[ -d "$origen" ]]; then
        origen+="/"
        destino+="/"
    fi

    dir_destino=$(dirname "$destino")
    if [[ ! -d "$dir_destino" ]]; then
        if [[ $DRY_RUN -eq 0 ]]; then
            mkdir -p "$dir_destino"
            printf "Directorio creado: %s\n" "$dir_destino"
            registrar_log "Directorio creado: $dir_destino"
        else
            printf "SIMULACIÓN: Se crearía el directorio: %s\n" "$dir_destino"
            registrar_log "SIMULACIÓN: Se crearía el directorio: $dir_destino"
        fi
    fi

    printf "\n${BLUE}--- Sincronizando: %s (%s) ---${NC}\n" "$elemento" "$direccion"
    registrar_log "Sincronizando: ${elemento} (${direccion})"

    printf "Comando: "
    printf "%q " rsync "${RSYNC_OPTS[@]}" "$origen" "$destino" # Imprime el comando de forma segura
    printf "\n"

    if rsync "${RSYNC_OPTS[@]}" "$origen" "$destino"; then
        printf "${GREEN}✓ Sincronización completada: %s${NC}\n" "$elemento"
        registrar_log "Sincronización completada: ${elemento}"
    else
        printf "${RED}✗ Error en sincronización: %s${NC}\n" "$elemento" >&2
        registrar_log "ERROR en sincronización: ${elemento}"
    fi
}

# --- Funciones para manejo de enlaces simbólicos ---

# Genera y sube un archivo con metadatos de los enlaces simbólicos
generar_archivo_enlaces() {
    local archivo_enlaces="$1"
    local pcloud_dir
    pcloud_dir=$(get_pcloud_dir)

    printf "Generando archivo de metadatos de enlaces simbólicos...\n"
    registrar_log "Generando archivo de enlaces: $archivo_enlaces"

    # Limpiar archivo existente
    > "$archivo_enlaces"

    local find_paths=()
    if [[ -n "$ITEM_ESPECIFICO" ]]; then
        find_paths+=("${LOCAL_DIR}/${ITEM_ESPECIFICO}")
    else
        while IFS= read -r elemento || [[ -n "$elemento" ]]; do
            if [[ -n "$elemento" && ! "$elemento" =~ ^[[:space:]]*# ]]; then
                find_paths+=("${LOCAL_DIR}/${elemento}")
            fi
        done < "$LISTA_SINCRONIZACION"
    fi

    # Buscar enlaces y guardar su ruta relativa y destino absoluto
    for path in "${find_paths[@]}"; do
        if [[ -e "$path" ]]; then
            find "$path" -type l -print0 | while IFS= read -d '' -r enlace; do
                local ruta_relativa
                ruta_relativa=$(realpath --relative-to="${LOCAL_DIR}" "$enlace")
                local destino
                destino=$(readlink -f "$enlace")
                printf "%s\t%s\n" "$ruta_relativa" "$destino" >> "$archivo_enlaces"
                registrar_log "Registrado enlace: ${ruta_relativa} -> ${destino}"
            done
        fi
    done

    if [[ -s "$archivo_enlaces" ]]; then
        printf "Subiendo archivo de metadatos de enlaces...\n"
        if rsync --progress --checksum "$archivo_enlaces" "${pcloud_dir}/${SYMLINKS_FILE}"; then
            registrar_log "Archivo de enlaces sincronizado a ${pcloud_dir}/${SYMLINKS_FILE}"
        else
            printf "${RED}✗ Error subiendo el archivo de metadatos de enlaces.${NC}\n" >&2
            registrar_log "ERROR subiendo el archivo de metadatos de enlaces."
        fi
    else
        printf "No se encontraron enlaces simbólicos para registrar.\n"
        registrar_log "No se encontraron enlaces simbólicos."
    fi
}

# Recrea los enlaces simbólicos a partir del archivo de metadatos
recrear_enlaces_desde_archivo() {
    local pcloud_dir archivo_origen
    pcloud_dir=$(get_pcloud_dir)
    archivo_origen="${pcloud_dir}/${SYMLINKS_FILE}"

    if [[ ! -f "$archivo_origen" ]]; then
        printf "No se encontró archivo de metadatos de enlaces, omitiendo recreación.\n"
        registrar_log "No se encontró ${archivo_origen}, no se recrean enlaces."
        return
    fi

    printf "Recreando enlaces simbólicos desde el archivo de metadatos...\n"

    while IFS=$'\t' read -r ruta_enlace destino || [[ -n "$ruta_enlace" ]]; do
        if [[ -z "$ruta_enlace" ]]; then continue; fi

        local ruta_completa="${LOCAL_DIR}/${ruta_enlace}"

        if [[ -L "$ruta_completa" && "$(readlink -f "$ruta_completa")" == "$destino" ]]; then
            registrar_log "Enlace ya existe y es correcto: ${ruta_enlace}"
            continue
        fi

        if [[ $DRY_RUN -eq 1 ]]; then
            printf "SIMULACIÓN: ln -sfn '%s' '%s'\n" "$destino" "$ruta_completa"
        else
            mkdir -p "$(dirname "$ruta_completa")"
            if ln -sfn "$destino" "$ruta_completa"; then
                printf "Enlace recreado: %s -> %s\n" "$ruta_enlace" "$destino"
                registrar_log "Enlace recreado: ${ruta_enlace} -> ${destino}"
            else
                printf "${RED}✗ Error recreando enlace: %s${NC}\n" "$ruta_enlace" >&2
                registrar_log "ERROR recreando enlace: ${ruta_enlace}"
            fi
        fi
    done < "$archivo_origen"
}

# Restaura los permisos de ejecución en ciertos archivos tras una descarga
ajustar_permisos_ejecutables() {
    printf "Ajustando permisos de ejecución...\n"

    for patron in "$@"; do
        # CORRECCIÓN: Se eliminan las comillas de la variable para permitir
        # la expansión de globs (wildcards como *) por parte de la shell.
        # Esto es seguro aquí porque las rutas base no contienen espacios.
        local rutas_a_modificar=${LOCAL_DIR}/${patron}
        
        # El comando 'shopt -s nullglob' hace que el patrón se expanda a nada si no encuentra archivos,
        # evitando un error si no hay ficheros que coincidan.
        shopt -s nullglob
        for fichero in $rutas_a_modificar; do
             if chmod +x "$fichero"; then
                printf "Permiso de ejecución añadido a: %s\n" "$fichero"
                registrar_log "Permiso +x añadido a ${fichero}"
            else
                printf "${YELLOW}Advertencia: No se pudo aplicar permiso de ejecución a %s.${NC}\n" "$fichero"
            fi
        done
        shopt -u nullglob # Se desactiva la opción para no afectar a otras partes del script.
    done
}


# --- Función Principal ---
main() {
    # Procesar argumentos de la línea de comandos
    while [[ $# -gt 0 ]]; do
        case $1 in
            --subir) MODO="subir"; shift ;;
            --bajar) MODO="bajar"; shift ;;
            --delete) DELETE=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --yes) YES=1; shift ;;
            --overwrite) OVERWRITE=1; shift ;;
            --backup-dir) BACKUP_DIR_MODE="readonly"; shift ;;
            --item)
                if [[ -z "${2:-}" ]]; then
                    printf "${RED}ERROR: La opción --item requiere un argumento.${NC}\n" >&2; exit 1
                fi
                ITEM_ESPECIFICO="$2"; shift 2 ;;
            --help) mostrar_ayuda; exit 0 ;;
            *) printf "${RED}ERROR: Opción desconocida: %s${NC}\n" "$1" >&2; mostrar_ayuda; exit 1 ;;
        esac
    done

    # Validaciones iniciales
    if [[ -z "$MODO" ]]; then
        printf "${RED}ERROR: Debes especificar --subir o --bajar.${NC}\n" >&2; mostrar_ayuda; exit 1
    fi

    verificar_dependencias
    find_config_files

    if [[ -z "$ITEM_ESPECIFICO" && -z "$LISTA_SINCRONIZACION" ]]; then
        printf "${RED}ERROR: No se encontró un archivo de lista de sincronización ni se usó --item.${NC}\n" >&2
        exit 1
    fi

    # Flujo de ejecución
    mostrar_banner
    verificar_pcloud_montado
    confirmar_ejecucion

    build_rsync_opts

    # Sincronización de archivos y directorios
    if [[ -n "$ITEM_ESPECIFICO" ]]; then
        sincronizar_elemento "$ITEM_ESPECIFICO"
    else
        while IFS= read -r linea || [[ -n "$linea" ]]; do
            if [[ -n "$linea" && ! "$linea" =~ ^[[:space:]]*# ]]; then
                sincronizar_elemento "$linea"
            fi
        done < "$LISTA_SINCRONIZACION"
    fi

    # Manejo de enlaces simbólicos
    if [[ "$MODO" == "subir" ]]; then
        local archivo_temporal
        archivo_temporal=$(mktemp)
        trap 'rm -f "$archivo_temporal"' EXIT # Asegura la limpieza del archivo temporal
        generar_archivo_enlaces "$archivo_temporal"
    elif [[ "$MODO" == "bajar" ]]; then
        recrear_enlaces_desde_archivo
    fi

    # Ajuste de permisos post-sincronización
    if [[ "$MODO" == "bajar" && $DRY_RUN -eq 0 ]]; then
        ajustar_permisos_ejecutables \
            ".local/bin/*" \
            ".config/dotfiles/*.sh"
    fi

    # Mensaje final
    printf "\n==========================================\n"
    local mensaje_final="Sincronización completada exitosamente"
    if [[ $DRY_RUN -eq 1 ]]; then
      mensaje_final="Simulación completada exitosamente"
    fi
    printf "${GREEN}✓ %s${NC}\n" "$mensaje_final"
    registrar_log "${mensaje_final}"
    printf "Log guardado en: %s\n" "$LOG_FILE"
    printf "==========================================\n"
}

# Ejecutar el script pasando todos los argumentos a la función main
main "$@"
