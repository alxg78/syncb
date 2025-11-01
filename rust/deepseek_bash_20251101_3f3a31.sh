# Subir archivos a pCloud
syncb --subir

# Bajar archivos desde pCloud
syncb --bajar

# Simular sincronización
syncb --subir --dry-run

# Sincronizar con eliminación de archivos obsoletos
syncb --subir --delete

# Sincronizar elementos específicos
syncb --subir --item Documentos/ --item .config/

# Excluir patrones
syncb --subir --exclude "*.tmp" --exclude "temp/"

# Incluir directorio Crypto
syncb --subir --crypto

# Límite de ancho de banda
syncb --subir --bwlimit 1000  # 1MB/s

# Timeout personalizado
syncb --subir --timeout 10  # 10 minutos