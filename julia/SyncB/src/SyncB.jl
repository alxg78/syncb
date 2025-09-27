module SyncB

# Exportar las funciones y tipos principales
export SyncBidireccional, main, parse_arguments, Config, Logger

# Incluir los módulos en ORDEN CORRECTO (sin dependencias circulares)
include("utils.jl")
include("config.jl")
include("logging.jl")

# Ahora definir los tipos básicos que otros módulos necesitan
include("syncbidireccional_types.jl")  # Nuevo archivo solo con structs básicos

include("argsparser.jl")  
include("symblinks.jl")
include("syncbidireccional_impl.jl")   # Implementación separada

# Función principal
function main()
    app = SyncBidireccional()
    return run(app)
end

# Para ejecutar desde línea de comandos
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module SyncB