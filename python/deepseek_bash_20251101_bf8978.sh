# Sincronizar subiendo
./syncb.py --subir

# Sincronizar bajando
./syncb.py --bajar

# Simular sincronización (dry-run)
./syncb.py --subir --dry-run

# Sincronizar con eliminación de archivos obsoletos
./syncb.py --bajar --delete

# Sincronizar elementos específicos
./syncb.py --subir --item Documentos/ --item .config/

# Sincronizar con exclusiones
./syncb.py --bajar --exclude '*.tmp' --exclude 'temp/'

# Sincronizar incluyendo directorio Crypto
./syncb.py --subir --crypto

# Sincronizar con límite de ancho de banda
./syncb.py --subir --bwlimit 1000

# Sincronizar con timeout específico
./syncb.py --bajar --timeout 10