#!/bin/bash

# Script de instalación minimalista
# Copia los archivos de sincronización a ~/.local/bin

TARGET_DIR="$HOME/.local/bin"
AUTO_MODE=0

# Función para mostrar ayuda
mostrar_ayuda() {
    echo "Uso: $0 [OPCIONES]"
    echo ""
    echo "Opciones:"
    echo "  -y, --yes    Instalar todos los archivos automáticamente sin preguntas"
    echo "  -h, --help   Mostrar esta ayuda"
    echo ""
    echo "Sin opciones: Modo interactivo (pregunta antes de sobrescribir)"
}

# Procesar argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
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

# Lista de archivos a copiar
FILES=(
    "syncb.sh"
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

echo "Iniciando instalación en modo ${AUTO_MODE:-interactivo}..."
echo "Directorio destino: $TARGET_DIR"
echo ""

# Función para verificar y copiar archivos
for file in "${FILES[@]}"; do
    # Verificar si el archivo fuente existe
    if [ ! -f "$file" ]; then
        echo "❌ ERROR: El archivo $file no existe en el directorio actual"
        ERRORES=$((ERRORES + 1))
        continue
    fi
    
    # Verificar si el archivo destino ya existe
    if [ -f "$TARGET_DIR/$file" ]; then
        if [ $AUTO_MODE -eq 1 ]; then
            # Modo automático: sobrescribir sin preguntar
            cp -v "$file" "$TARGET_DIR/"
            SOBRESCRITOS=$((SOBRESCRITOS + 1))
            echo "✅ $file (sobrescrito)"
        else
            # Modo interactivo: preguntar al usuario
            echo "El archivo $file ya existe en $TARGET_DIR"
            read -p "¿Deseas sobrescribirlo? (s/N): " answer
            if [[ "$answer" =~ ^[SsyY]$ ]]; then
                cp -v "$file" "$TARGET_DIR/"
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
        cp -v "$file" "$TARGET_DIR/"
        COPIADOS=$((COPIADOS + 1))
        echo "✅ $file (copiado)"
    fi
    
    # Establecer permisos de ejecución para el script principal
    if [ "$file" = "syncb.sh" ]; then
        chmod +x "$TARGET_DIR/$file"
        echo "🔒 Permisos de ejecución asignados a $file"
    fi
done

# Mostrar resumen
echo ""
echo "=========================================="
echo "RESUMEN DE INSTALACIÓN"
echo "=========================================="
echo "Archivos nuevos copiados: $COPIADOS"
echo "Archivos sobrescritos: $SOBRESCRITOS"
echo "Archivos omitidos: $OMITIDOS"
echo "Errores: $ERRORES"
echo ""

if [ $ERRORES -eq 0 ]; then
    echo "✅ Proceso de instalación completado con éxito"
else
    echo "⚠️  Proceso de instalación completado con $ERRORES error(es)"
fi

# Mostrar mensaje final con información de uso
if [ -f "$TARGET_DIR/syncb.sh" ]; then
    echo ""
    echo "Para usar el script de sincronización, ejecuta:"
    echo "  $TARGET_DIR/syncb.sh --help"
fi
