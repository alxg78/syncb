# Solo las definiciones de structs básicas, sin dependencias complejas
mutable struct SyncBidireccional
    config::Config
    logger::Logger
    modo::String
    dry_run::Bool
    delete::Bool
    yes::Bool
    overwrite::Bool
    backup_dir_mode::String
    verbose::Bool
    use_checksum::Bool
    bw_limit::Union{Int, Nothing}
    timeout_minutes::Int
    items_especificos::Vector{String}
    exclusiones_cli::Vector{String}
    sync_crypto::Bool
    elementos_procesados::Int
    errores_sincronizacion::Int
    archivos_transferidos::Int
    archivos_borrados::Int
    archivos_crypto_transferidos::Int
    start_time::Float64
    hostname::String
    lock_file::String
end

# Constructor básico
function SyncBidireccional(config_file::Union{String, Nothing}=nothing)
    config = Config(config_file)
    logger = setup_logging!(config)
    
    SyncBidireccional(
        config, logger,
        "", false, false, false, false, "comun", false, false, nothing, 30,
        String[], String[], false,
        0, 0, 0, 0, 0,
        time(), gethostname(), tempdir() * "/syncb.lock"
    )
end

