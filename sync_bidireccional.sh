#!/bin/bash

# Script: sync_bidireccional_v3.sh
# Descripción: Sincronización bidireccional mejorada entre directorio local y pCloud.
# Uso:
#   Subir: ./sync_bidireccional_v3.sh --subir [--delete] [--dry-run] [--item elemento] [--yes] [--overwrite]
#   Bajar: ./sync_bidireccional_v3.sh --bajar [--delete] [--dry-run] [--item elemento] [--yes] [--backup-dir] [--overwrite]

# --------------------------------------------------------------------------------------------------
# CONFIGURACIÓN
# --------------------------------------------------------------------------------------------------

# Editar estas rutas según tu caso. Utiliza rutas absolutas.
readonly PCLOUD_MOUNT_POINT="${HOME}/pCloudDrive"
readonly LOCAL_DIR="${HOME}"
readonly PCLOUD_BACKUP_COMUN="${PCLOUD_MOUNT_POINT}/Backups/Backup_Comun"
readonly PCLOUD_BACKUP_READONLY="${PCLOUD_MOUNT_POINT}/pCloud Backup/feynman.sobremesa.dnf"

# Nombre de archivo de configuración por defecto
readonly DEFAULT_LIST_FILE="sync_bidireccional_directorios.ini"
readonly EXCLUSIONS_FILE="sync_bidireccional_exclusiones.ini"
readonly SYMLINKS_METADATA_FILE=".sync_bidireccional_symlinks.meta"

# Hostname específico que usa una configuración diferente
readonly HOSTNAME_RTVA="feynman.rtva.dnf"

# --------------------------------------------------------------------------------------------------
# VARIABLES GLOBALES
# --------------------------------------------------------------------------------------------------

MODO=""
DRY_RUN=0
DELETE=0
ITEM_ESPECIFICO=""
YES=0
OVERWRITE=0
BACKUP_DIR_MODE="comun" # "comun" or "readonly"
LISTA_SINCRONIZACION=""
EXCLUSIONES=""
LOG_FILE="${HOME}/sync_bidireccional.log"

# Códigos de color
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# --------------------------------------------------------------------------------------------------
# FUNCIONES AUXILIARES
# --------------------------------------------------------------------------------------------------

# Muestra un mensaje de error y sale.
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

# Muestra un mensaje de advertencia.
warning() {
    echo -e "${YELLOW}ADVERTENCIA: $1${NC}"
}

# Muestra un mensaje de éxito.
success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Registra un mensaje en el archivo de log.
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Muestra el menú de ayuda del script.
show_help() {
    echo "Uso: $(basename "$0") [OPCIONES]"
    echo ""
    echo "Descripción: Sincronización bidireccional entre directorio local y pCloud."
    echo ""
    echo "Opciones:"
    echo "  --subir            Sincroniza los archivos del directorio local a pCloud."
    echo "  --bajar            Sincroniza los archivos de pCloud al directorio local."
    echo "  --item <elemento>  Sincroniza solo un elemento (archivo o directorio) específico."
    echo "  --delete           Activa la eliminación de archivos en el destino que no existan en el origen."
    echo "  --dry-run          Realiza una simulación sin hacer cambios reales."
    echo "  --yes              Omite la confirmación del usuario para iniciar la sincronización."
    echo "  --backup-dir       Utiliza el directorio de solo lectura para bajar los archivos."
    echo "  --overwrite        Sincroniza todos los archivos, incluso si el destino es más nuevo."
    echo "  --help             Muestra este mensaje de ayuda y sale."
    echo ""
    echo "Ejemplos:"
    echo "  Sincronizar todo el local a pCloud (simulación):"
    echo "    $(basename "$0") --subir --dry-run"
    echo ""
    echo "  Bajar un directorio específico y eliminar archivos antiguos:"
    echo "    $(basename "$0") --bajar --item '.config/nvim' --delete"
    exit 0
}

# Determina el directorio de pCloud según el modo.
get_pcloud_dir() {
    if [[ "$BACKUP_DIR_MODE" == "readonly" ]]; then
        echo "$PCLOUD_BACKUP_READONLY"
    else
        echo "$PCLOUD_BACKUP_COMUN"
    fi
}

# --------------------------------------------------------------------------------------------------
# LÓGICA DEL SCRIPT
# --------------------------------------------------------------------------------------------------

## Verificación de Dependencias
verificar_dependencias() {
    if ! command -v rsync &>/dev/null; then
        error_exit "rsync no está instalado. Instálalo con 'sudo apt install rsync' o 'sudo dnf install rsync'."
    fi
}

## Búsqueda y Verificación de Archivos de Configuración
find_config_files() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local hostname=$(hostname)

    if [[ "$hostname" == "$HOSTNAME_RTVA" ]]; then
        LISTA_SINCRONIZACION="${script_dir}/sync_bidireccional_directorios_${HOSTNAME_RTVA}.ini"
    else
        LISTA_SINCRONIZACION="${script_dir}/${DEFAULT_LIST_FILE}"
    fi

    # Verificar si el archivo de lista existe
    if [[ -z "$ITEM_ESPECIFICO" ]] && [[ ! -f "$LISTA_SINCRONIZACION" ]]; then
        error_exit "No se encontró el archivo de lista: '$LISTA_SINCRONIZACION'.\nCrea un archivo con la lista de rutas a sincronizar o usa --item."
    fi

    # Buscar el archivo de exclusiones
    local exclusions_path="${script_dir}/${EXCLUSIONS_FILE}"
    if [[ -f "$exclusions_path" ]]; then
        EXCLUSIONES="$exclusions_path"
    else
        warning "No se encontró el archivo de exclusiones: '$EXCLUSIONS_FILE'. No se aplicarán exclusiones."
    fi
}

## Verificación de pCloud Montado
verificar_pcloud_montado() {
    local pcloud_dir=$(get_pcloud_dir)

    if [[ ! -d "$PCLOUD_MOUNT_POINT" ]]; then
        error_exit "El punto de montaje de pCloud no existe: '$PCLOUD_MOUNT_POINT'. Asegúrate de que pCloud Drive esté instalado y ejecutándose."
    fi

    if [[ -z "$(ls -A "$PCLOUD_MOUNT_POINT" 2>/dev/null)" ]]; then
        error_exit "El directorio de pCloud está vacío: '$PCLOUD_MOUNT_POINT'. Esto sugiere que pCloud Drive no está montado correctamente."
    fi

    if [[ ! -d "$pcloud_dir" ]]; then
        error_exit "El directorio de pCloud no existe: '$pcloud_dir'. Asegúrate de que exista en tu cuenta."
    fi

    if [[ $DRY_RUN -eq 0 ]] && [[ "$BACKUP_DIR_MODE" == "comun" ]]; then
        if ! touch "${pcloud_dir}/.test_write_$$" &>/dev/null; then
            error_exit "No se puede escribir en el directorio de pCloud: '$pcloud_dir'. Revisa tus permisos."
        fi
        rm -f "${pcloud_dir}/.test_write_$$"
    fi

    success "Verificación de pCloud: El directorio está montado y accesible."
}

## Lógica de Sincronización
sincronizar_elemento() {
    local elemento="$1"
    local pcloud_dir=$(get_pcloud_dir)

    local origen="${LOCAL_DIR}/${elemento}"
    local destino="${pcloud_dir}/${elemento}"
    local direccion="LOCAL → PCLOUD (Subir)"

    if [[ "$MODO" == "bajar" ]]; then
        origen="${pcloud_dir}/${elemento}"
        destino="${LOCAL_DIR}/${elemento}"
        direccion="PCLOUD → LOCAL (Bajar)"
    fi

    # Manejar rutas que son directorios
    if [[ -d "$origen" ]]; then
        origen="${origen%/}/"
        destino="${destino%/}/"
    fi

    if [[ ! -e "$origen" ]]; then
        warning "El origen no existe, omitiendo: $origen"
        log_message "ADVERTENCIA: No existe $origen"
        return 1
    fi
    
    echo -e "${BLUE}Sincronizando: $elemento ($direccion)${NC}"
    log_message "Sincronizando: $elemento ($direccion)"

    # Construir opciones de rsync en un array para mayor seguridad
    local rsync_args=(
        "--recursive"
        "--verbose"
        "--times"
        "--checksum"
        "--progress"
        "--no-links"
    )
    
    [[ $OVERWRITE -eq 0 ]] && rsync_args+=("--update")
    [[ $DRY_RUN -eq 1 ]] && rsync_args+=("--dry-run")
    [[ $DELETE -eq 1 ]] && rsync_args+=("--delete-delay")
    
    # Añadir exclusiones de forma segura
    if [[ -n "$EXCLUSIONES" ]]; then
        while IFS= read -r exclusion; do
            if [[ -n "$exclusion" ]] && [[ ! "$exclusion" =~ ^[[:space:]]*# ]]; then
                rsync_args+=("--exclude=${exclusion}")
            fi
        done < "$EXCLUSIONES"
    fi

    # Añadir origen y destino al array de argumentos
    rsync_args+=("${origen}" "${destino}")
    
    log_message "Comando: rsync ${rsync_args[*]}"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "SIMULACIÓN: rsync ${rsync_args[*]}"
        log_message "SIMULACIÓN: rsync ${rsync_args[*]}"
        return 0
    fi
    
    # Ejecutar rsync con los argumentos del array
    rsync "${rsync_args[@]}"
    local resultado=$?

    if [[ $resultado -eq 0 ]]; then
        success "Sincronización completada: $elemento"
        log_message "Sincronización completada: $elemento"
    else
        echo -e "${RED}✗ Error en sincronización: $elemento (código: $resultado)${NC}"
        log_message "Error en sincronización: $elemento (código: $resultado)"
    fi
    return $resultado
}

## Manejo de Enlaces Simbólicos
sincronizar_symlinks() {
    if [[ "$MODO" == "subir" ]]; then
        # Subir: Generar y subir el archivo de metadatos de enlaces
        log_message "Generando y subiendo metadatos de enlaces simbólicos."
        local symlinks_temp_file=$(mktemp)
        
        if [[ -n "$ITEM_ESPECIFICO" ]]; then
            find "${LOCAL_DIR}/${ITEM_ESPECIFICO}" -type l 2>/dev/null
        else
            while IFS= read -r item; do
                if [[ -n "$item" ]] && [[ ! "$item" =~ ^[[:space:]]*# ]]; then
                    find "${LOCAL_DIR}/${item}" -type l 2>/dev/null
                fi
            done < "$LISTA_SINCRONIZACION"
        fi | while read -r link; do
            local relative_path=$(realpath --relative-to="${LOCAL_DIR}" "$link")
            local target=$(readlink -f "$link")
            if [[ -n "$relative_path" ]] && [[ -n "$target" ]]; then
                echo -e "${relative_path}\t${target}" >> "$symlinks_temp_file"
            fi
        done

        if [[ -s "$symlinks_temp_file" ]]; then
            rsync --dry-run "${symlinks_temp_file}" "$(get_pcloud_dir)/${SYMLINKS_METADATA_FILE}" >/dev/null
            if [[ $? -eq 0 ]]; then
                echo "SIMULACIÓN: Se subiría el archivo de metadatos de enlaces."
            else
                rsync --progress "${symlinks_temp_file}" "$(get_pcloud_dir)/${SYMLINKS_METADATA_FILE}"
                success "Archivo de metadatos de enlaces subido."
            fi
        fi
        rm -f "$symlinks_temp_file"
    elif [[ "$MODO" == "bajar" ]]; then
        # Bajar: Recrear enlaces desde el archivo de metadatos
        log_message "Recreando enlaces simbólicos desde metadatos."
        local pcloud_symlinks_path="$(get_pcloud_dir)/${SYMLINKS_METADATA_FILE}"

        if [[ ! -f "$pcloud_symlinks_path" ]]; then
            warning "No se encontró el archivo de metadatos de enlaces, se omite la recreación."
            return 0
        fi

        while IFS=$'\t' read -r link_path target; do
            if [[ -z "$link_path" ]]; then continue; fi
            local full_link_path="${LOCAL_DIR}/${link_path}"
            
            # Si el enlace ya existe y es correcto, se omite
            if [[ -L "$full_link_path" ]] && [[ "$(readlink -f "$full_link_path")" == "$target" ]]; then
                continue
            fi

            # Si el destino del enlace no existe, se advierte
            if [[ ! -e "$target" ]]; then
                warning "El destino del enlace no existe en el sistema local: '$target'"
                continue
            fi

            local parent_dir=$(dirname "$full_link_path")
            if [[ ! -d "$parent_dir" ]]; then
                echo "Creando directorio padre: $parent_dir"
                mkdir -p "$parent_dir"
            fi

            if [[ $DRY_RUN -eq 1 ]]; then
                echo "SIMULACIÓN: ln -sfn '$target' '$full_link_path'"
            else
                if ln -sfn "$target" "$full_link_path" &>/dev/null; then
                    echo "Creado enlace: ${link_path} -> ${target}"
                else
                    warning "Error al crear enlace: ${link_path}"
                fi
            fi
        done < "$pcloud_symlinks_path"
    fi
}

## Ajuste de Permisos
ajustar_permisos_ejecutables() {
    local exit_code=0
    echo -e "${BLUE}Ajustando permisos de ejecución...${NC}"

    for pattern in "$@"; do
        if [[ "$pattern" == *"*"* ]]; then
            # Es un patrón con comodín
            local full_path_pattern="${LOCAL_DIR}/${pattern}"
            find "$(dirname "$full_path_pattern")" -maxdepth 1 -name "$(basename "$full_path_pattern")" -type f -exec chmod +x {} +
        else
            # Es una ruta específica
            local full_path="${LOCAL_DIR}/${pattern}"
            if [[ ! -e "$full_path" ]]; then
                warning "La ruta no existe, se omite: $full_path"
                continue
            fi
            if [[ -f "$full_path" ]]; then
                echo "Aplicando permisos a: $pattern"
                chmod +x "$full_path"
            elif [[ -d "$full_path" ]]; then
                echo "Aplicando permisos recursivos a: $pattern"
                find "$full_path" -type f \( -name "*.sh" -o -name "*.py" -o -name "*.jl" \) -exec chmod +x {} +
            fi
        fi
    done
}

## Función Principal (main)
main() {
    # Manejo de argumentos
    if [[ $# -eq 0 ]]; then
        show_help
    fi

    # Usar un bucle while y case para procesar argumentos de forma robusta
    while [[ $# -gt 0 ]]; do
        case $1 in
            --subir)
                [[ -n "$MODO" ]] && error_exit "No puedes usar --subir y --bajar simultáneamente."
                MODO="subir"
                shift
                ;;
            --bajar)
                [[ -n "$MODO" ]] && error_exit "No puedes usar --subir y --bajar simultáneamente."
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
                [[ $# -lt 2 ]] && error_exit "La opción --item requiere un argumento."
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
                show_help
                ;;
            *)
                error_exit "Opción desconocida: '$1'. Usa --help para ver las opciones disponibles."
                ;;
        esac
    done

    # Validaciones iniciales
    [[ -z "$MODO" ]] && error_exit "Debes especificar --subir o --bajar. Usa --help para ver las opciones."
    verificar_dependencias
    find_config_files
    verificar_pcloud_montado
    log_message "Sincronización iniciada: $(date)"

    # Confirmación
    if [[ $DRY_RUN -eq 0 ]] && [[ $YES -eq 0 ]]; then
        read -p "¿Desea continuar con la sincronización? [s/N]: " respuesta
        [[ "$respuesta" != "s" ]] && [[ "$respuesta" != "S" ]] && exit 0
    fi

    # Sincronizar
    local exit_code=0
    if [[ -n "$ITEM_ESPECIFICO" ]]; then
        sincronizar_elemento "$ITEM_ESPECIFICO" || exit_code=1
    else
        while IFS= read -r line; do
            if [[ -n "$line" ]] && [[ ! "$line" =~ ^[[:space:]]*# ]]; then
                sincronizar_elemento "$line" || exit_code=1
            fi
        done < "$LISTA_SINCRONIZACION"
    fi

    # Manejar enlaces simbólicos
    sincronizar_symlinks

    # Ajustar permisos si es necesario
    if [[ "$MODO" == "bajar" ]] && [[ $DRY_RUN -eq 0 ]]; then
        ajustar_permisos_ejecutables \
            ".local/bin/*.sh" \
            ".local/bin/*.bash" \
            ".local/bin/*.py" \
            ".local/bin/pcloud" \
            ".config/dotfiles/*.sh"
    fi

    # Finalizar
    log_message "Sincronización finalizada con código de salida: $exit_code"
    if [[ $exit_code -eq 0 ]]; then
        success "Sincronización completada exitosamente."
    else
        error_exit "Sincronización finalizada con errores."
    fi
}

# Ejecutar la función principal
main "$@"