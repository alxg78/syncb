# Sincronización completa con Crypto
julia syncb.jl --subir --crypto --yes

# Sincronización selectiva con límite de ancho de banda
julia syncb.jl --bajar --item proyectos/ --bwlimit 1000 --timeout 10

# Verificación sin cambios
julia syncb.jl --subir --dry-run --verbose