#!/bin/bash

# Script de instalación para syncb (Bash, Python y Julia)
# Copia los archivos de sincronización a ~/.local/bin

TARGET_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/syncb"
AUTO_MODE=0
INSTALL_BASH=0
INSTALL_PYTHON=0
INSTALL_JULIA=0
UNINSTALL_BASH=0
UNINSTALL_PYTHON=0
UNINSTALL_JULIA=0
UNINSTALL_ALL=0

# Función para mostrar ayuda
mostrar_ayuda() {
    echo "Uso: $0 [OPCIONES]"
    echo ""
    echo "Opciones de instalación:"
    echo "  --install_bash      Instalar versión Bash"
    echo "  --install_python    Instalar versión Python"
    echo "  --install_julia     Instalar versión Julia"
    echo "  --install_all       Instalar todas las versiones"
    echo ""
    echo "Opciones de desinstalación:"
    echo "  --uninstall_bash    Desinstalar versión Bash"
    echo "  --uninstall_python  Desinstalar versión Python"
    echo "  --uninstall_julia   Desinstalar versión Julia"
    echo "  --uninstall_all     Desinstalar todas las versiones"
    echo ""
    echo "Opciones generales:"
    echo "  -y, --yes           Modo automático (sin confirmaciones)"
    echo "  -h, --help          Mostrar esta ayuda"
    echo ""
    echo "Sin opciones: Modo interactivo (pregunta antes de sobrescribir)"
    echo ""
    echo "Ejemplos:"
    echo "  $0 --install_bash --install_python"
    echo "  $0 --uninstall_all -y"
    echo "  $0 --install_all --yes"
}

# Procesar argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --install_bash)
            INSTALL_BASH=1
            shift
            ;;
        --install_python)
            INSTALL_PYTHON=1
            shift
            ;;
        --install_julia)
            INSTALL_JULIA=1
            shift
            ;;
        --install_all)
            INSTALL_BASH=1
            INSTALL_PYTHON=1
            INSTALL_JULIA=1
            shift
            ;;
        --uninstall_bash)
            UNINSTALL_BASH=1
            shift
            ;;
        --uninstall_python)
            UNINSTALL_PYTHON=1
            shift
            ;;
        --uninstall_julia)
            UNINSTALL_JULIA=1
            shift
            ;;
        --uninstall_all)
            UNINSTALL_ALL=1
            shift
            ;;
        -y|--yes)
            AUTO_MODE=1
            shift
            ;;
        -h|--help)
            mostrar_ayuda
            exit 0
            ;;
        *)
            echo "Opción desconocida: $1"
            mostrar_ayuda
            exit 1
            ;;
    esac
done

# Si no se especificó ninguna opción, mostrar ayuda y salir
if [ $INSTALL_BASH -eq 0 ] && [ $INSTALL_PYTHON -eq 0 ] && [ $INSTALL_JULIA -eq 0 ] &&
   [ $UNINSTALL_BASH -eq 0 ] && [ $UNINSTALL_PYTHON -eq 0 ] && [ $UNINSTALL_JULIA -eq 0 ] && [ $UNINSTALL_ALL -eq 0 ]; then
    mostrar_ayuda
    exit 0
fi

# Verificar si el directorio destino existe
if [ ! -d "$TARGET_DIR" ]; then
    echo "El directorio $TARGET_DIR no existe."
    
    if [ $AUTO_MODE -eq 1 ]; then
        echo "Creando directorio $TARGET_DIR..."
        mkdir -p "$TARGET_DIR"
    else
        echo "Por favor, créalo manualmente: mkdir -p $TARGET_DIR"
        exit 1
    fi
fi

# Verificar si el directorio de configuración existe
if [ ! -d "$CONFIG_DIR" ]; then
    echo "El directorio $CONFIG_DIR no existe."
    
    if [ $AUTO_MODE -eq 1 ]; then
        echo "Creando directorio $CONFIG_DIR..."
        mkdir -p "$CONFIG_DIR"
    else
        read -p "¿Desea crear el directorio de configuración $CONFIG_DIR? (s/N): " answer
        if [[ "$answer" =~ ^[SsyY]$ ]]; then
            mkdir -p "$CONFIG_DIR"
        else
            echo "Continuando sin directorio de configuración..."
        fi
    fi
fi

# Archivos para cada versión
BASH_FILES=(
    "syncb.sh"
    "syncb_directorios.ini"
    "syncb_directorios_feynman.rtva.dnf.ini"
    "syncb_exclusiones.ini"
    "syncb_readme.org"
)

PYTHON_FILES=(
    "syncb.py"
    "syncb_config.toml"
    "syncb_readme.org"
)

JULIA_FILES=(
    "syncb.jl"
    "syncb_directorios.ini"
    "syncb_directorios_feynman.rtva.dnf.ini"
    "syncb_exclusiones.ini"
    "syncb_readme.org"
)

# Contadores para estadísticas
COPIADOS=0
SOBRESCRITOS=0
OMITIDOS=0
ERRORES=0
ELIMINADOS=0

# Función para copiar archivos
copiar_archivos() {
    local files=("$@")
    local target_dir="$1"
    shift
    local files=("$@")
    
    for file in "${files[@]}"; do
        # Verificar si el archivo fuente existe
        if [ ! -f "$file" ]; then
            echo "❌ ERROR: El archivo $file no existe en el directorio actual"
            ERRORES=$((ERRORES + 1))
            continue
        fi
        
        # Verificar si el archivo destino ya existe
        if [ -f "$target_dir/$file" ]; then
            if [ $AUTO_MODE -eq 1 ]; then
                # Modo automático: sobrescribir sin preguntar
                cp -v "$file" "$target_dir/"
                SOBRESCRITOS=$((SOBRESCRITOS + 1))
                echo "✅ $file (sobrescrito)"
            else
                # Modo interactivo: preguntar al usuario
                echo "El archivo $file ya existe en $target_dir"
                read -p "¿Deseas sobrescribirlo? (s/N): " answer
                if [[ "$answer" =~ ^[SsyY]$ ]]; then
                    cp -v "$file" "$target_dir/"
                    SOBRESCRITOS=$((SOBRESCRITOS + 1))
                    echo "✅ $file (sobrescrito)"
                else
                    echo "⏭️  $file (omitido)"
                    OMITIDOS=$((OMITIDOS + 1))
                    continue
                fi
            fi
        else
            # El archivo no existe en destino, copiar normalmente
            cp -v "$file" "$target_dir/"
            COPIADOS=$((COPIADOS + 1))
            echo "✅ $file (copiado)"
        fi
        
        # Establecer permisos de ejecución para scripts
        if [[ "$file" == *.sh || "$file" == *.py ]]; then
            chmod +x "$target_dir/$file"
            echo "🔒 Permisos de ejecución asignados a $file"
        fi
    done
}

# Función para eliminar archivos
eliminar_archivos() {
    local files=("$@")
    local target_dir="$1"
    shift
    local files=("$@")
    
    for file in "${files[@]}"; do
        # Verificar si el archivo existe en destino
        if [ -f "$target_dir/$file" ]; then
            if [ $AUTO_MODE -eq 1 ]; then
                # Modo automático: eliminar sin preguntar
                rm -v "$target_dir/$file"
                ELIMINADOS=$((ELIMINADOS + 1))
                echo "🗑️  $file (eliminado)"
            else
                # Modo interactivo: preguntar al usuario
                read -p "¿Deseas eliminar $target_dir/$file? (s/N): " answer
                if [[ "$answer" =~ ^[SsyY]$ ]]; then
                    rm -v "$target_dir/$file"
                    ELIMINADOS=$((ELIMINADOS + 1))
                    echo "🗑️  $file (eliminado)"
                else
                    echo "⏭️  $file (conservado)"
                fi
            fi
        else
            echo "ℹ️  $file no existe en $target_dir"
        fi
    done
}

# Procesar instalaciones
if [ $INSTALL_BASH -eq 1 ]; then
    echo "Instalando versión Bash..."
    copiar_archivos "$TARGET_DIR" "${BASH_FILES[@]}"
    # Copiar también archivos de configuración al directorio de configuración
    copiar_archivos "$CONFIG_DIR" "syncb_directorios.ini" "syncb_directorios_feynman.rtva.dnf.ini" "syncb_exclusiones.ini"
fi

if [ $INSTALL_PYTHON -eq 1 ]; then
    echo "Instalando versión Python..."
    copiar_archivos "$TARGET_DIR" "${PYTHON_FILES[@]}"
    # Copiar también archivos de configuración al directorio de configuración
    copiar_archivos "$CONFIG_DIR" "syncb_config.toml"
fi

if [ $INSTALL_JULIA -eq 1 ]; then
    echo "Instalando versión Julia..."
    copiar_archivos "$TARGET_DIR" "${JULIA_FILES[@]}"
    # Copiar también archivos de configuración al directorio de configuración
    copiar_archivos "$CONFIG_DIR" "syncb_julia_config.toml"
fi

# Procesar desinstalaciones
if [ $UNINSTALL_BASH -eq 1 ] || [ $UNINSTALL_ALL -eq 1 ]; then
    echo "Desinstalando versión Bash..."
    eliminar_archivos "$TARGET_DIR" "${BASH_FILES[@]}"
    # Eliminar también archivos de configuración
    eliminar_archivos "$CONFIG_DIR" "syncb_directorios.ini" "syncb_directorios_feynman.rtva.dnf.ini" "syncb_exclusiones.ini"
fi

if [ $UNINSTALL_PYTHON -eq 1 ] || [ $UNINSTALL_ALL -eq 1 ]; then
    echo "Desinstalando versión Python..."
    eliminar_archivos "$TARGET_DIR" "${PYTHON_FILES[@]}"
    # Eliminar también archivos de configuración
    eliminar_archivos "$CONFIG_DIR" "syncb_config.toml"
fi

if [ $UNINSTALL_JULIA -eq 1 ] || [ $UNINSTALL_ALL -eq 1 ]; then
    echo "Desinstalando versión Julia..."
    eliminar_archivos "$TARGET_DIR" "${JULIA_FILES[@]}"
    # Eliminar también archivos de configuración
    eliminar_archivos "$CONFIG_DIR" "syncb_julia_config.toml"
fi

# Mostrar resumen
echo ""
echo "=========================================="
echo "RESUMEN DE OPERACIÓN"
echo "=========================================="

if [ $INSTALL_BASH -eq 1 ] || [ $INSTALL_PYTHON -eq 1 ] || [ $INSTALL_JULIA -eq 1 ]; then
    echo "INSTALACIÓN:"
    echo "Archivos nuevos copiados: $COPIADOS"
    echo "Archivos sobrescritos: $SOBRESCRITOS"
    echo "Archivos omitidos: $OMITIDOS"
    echo ""
fi

if [ $UNINSTALL_BASH -eq 1 ] || [ $UNINSTALL_PYTHON -eq 1 ] || [ $UNINSTALL_JULIA -eq 1 ] || [ $UNINSTALL_ALL -eq 1 ]; then
    echo "DESINSTALACIÓN:"
    echo "Archivos eliminados: $ELIMINADOS"
    echo ""
fi

echo "Errores: $ERRORES"
echo ""

if [ $ERRORES -eq 0 ]; then
    echo "✅ Proceso completado con éxito"
else
    echo "⚠️  Proceso completado con $ERRORES error(es)"
fi

# Mostrar mensaje final con información de uso
if [ -f "$TARGET_DIR/syncb.sh" ] && ([ $INSTALL_BASH -eq 1 ] || [ $UNINSTALL_BASH -eq 0 ]); then
    echo ""
    echo "Para usar la versión Bash:"
    echo "  $TARGET_DIR/syncb.sh --help"
fi

if [ -f "$TARGET_DIR/syncb.py" ] && ([ $INSTALL_PYTHON -eq 1 ] || [ $UNINSTALL_PYTHON -eq 0 ]); then
    echo ""
    echo "Para usar la versión Python:"
    echo "  $TARGET_DIR/syncb.py --help"
fi

if [ -f "$TARGET_DIR/syncb.jl" ] && ([ $INSTALL_JULIA -eq 1 ] || [ $UNINSTALL_JULIA -eq 0 ]); then
    echo ""
    echo "Para usar la versión Julia:"
    echo "  julia $TARGET_DIR/syncb.jl --help"
fi