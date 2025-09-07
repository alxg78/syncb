#!/bin/bash

# Script de instalación minimalista
# Copia los archivos de sincronización a ~/.local/bin

TARGET_DIR="$HOME/.local/bin"

# Verificar si el directorio destino existe
if [ ! -d "$TARGET_DIR" ]; then
    echo "El directorio $TARGET_DIR no existe."
    echo "Por favor, créalo manualmente: mkdir -p $TARGET_DIR"
    exit 1
fi

# Lista de archivos a copiar
FILES=(
    "sync_bidireccional.sh"
    "sync_bidireccional_directorios.ini"
    "sync_bidireccional_directorios_feynman.rtva.dnf.ini"
    "sync_bidireccional_exclusiones.ini"
    "sync_bidireccional_readme.org"
)

# Función para verificar y copiar archivos
for file in "${FILES[@]}"; do
    # Verificar si el archivo fuente existe
    if [ ! -f "$file" ]; then
        echo "ADVERTENCIA: El archivo $file no existe en el directorio actual"
        continue
    fi
    
    # Verificar si el archivo destino ya existe
    if [ -f "$TARGET_DIR/$file" ]; then
        echo "El archivo $file ya existe en $TARGET_DIR"
        read -p "¿Deseas sobrescribirlo? (s/N): " answer
        if [[ ! "$answer" =~ ^[Ss]$ ]]; then
            echo "Saltando $file"
            continue
        fi
    fi
    
    # Copiar el archivo
    cp -v "$file" "$TARGET_DIR/"
    
    # Establecer permisos de ejecución para el script principal
    if [ "$file" = "sync_bidireccional.sh" ]; then
        chmod +x "$TARGET_DIR/$file"
        echo "Permisos de ejecución asignados a $file"
    fi
done

echo "Proceso de instalación completado"
