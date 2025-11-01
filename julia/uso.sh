# Sincronizar subiendo
julia syncb.jl --subir

# Sincronizar bajando
julia syncb.jl --bajar

# Modo simulación
julia syncb.jl --subir --dry-run

# Sincronizar elementos específicos
julia syncb.jl --subir --item Documentos/ --item .config/

# Con exclusión de patrones
julia syncb.jl --subir --exclude "*.tmp" --exclude "temp/"

# Con todas las opciones
julia syncb.jl --subir --delete --yes --crypto --verbose