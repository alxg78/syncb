 module SyncB

using Logging
using Dates
using TOML
using FilePathsBase
using ArgParse
using Sockets
using Glob

# Incluir todos los módulos
include("utils.jl")
include("config.jl")
include("logging.jl")
include("symblinks.jl")
include("syncbidireccional.jl")

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
