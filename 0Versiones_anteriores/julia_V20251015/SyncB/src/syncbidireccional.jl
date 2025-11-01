#?module SyncBidireccionalModule

#?using ..ConfigModule: Config
#?using ..LoggingModule: Logger, setup_logging!, log_info, log_warn, log_error, log_debug, log_success
#?using ..SymbLinksModule: SymbLinksManager, generar_archivo_enlaces, recrear_enlaces_desde_archivo
#?using ..ArgsParserModule: parse_arguments
#?using ..UtilsModule: cleanup_temporales, manejo_temporal_context
#?using FilePathsBase
#?using Dates
#?using Sockets

#?export SyncBidireccional, run

mutable struct SyncBidireccional
    config::Config
    logger::Logger
    symb_links_manager::SymbLinksManager
    
    # Parámetros de ejecución
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
    
    # Estadísticas
    elementos_procesados::Int
    errores_sincronizacion::Int
    archivos_transferidos::Int
    archivos_borrados::Int
    archivos_crypto_transferidos::Int
    
    # Tiempo
    start_time::Float64
    hostname::String
    
    # Lock file
    lock_file::AbstractPath
    
    function SyncBidireccional(config_file::Union{String, Nothing}=nothing)
        # Cargar configuración
        config = Config(config_file)
        
        # Configurar logging
        logger = setup_logging!(config)
        
        # Inicializar manager de enlaces
        symb_links_manager = SymbLinksManager(config, logger)
        
        # Valores por defecto
        modo = ""
        dry_run = false
        delete = false
        yes = false
        overwrite = false
        backup_dir_mode = "comun"
        verbose = false
        use_checksum = false
        bw_limit = nothing
        timeout_minutes = config.default_timeout_minutes
        items_especificos = String[]
        exclusiones_cli = String[]
        sync_crypto = false
        
        # Estadísticas
        elementos_procesados = 0
        errores_sincronizacion = 0
        archivos_transferidos = 0
        archivos_borrados = 0
        archivos_crypto_transferidos = 0
        
        # Tiempo y hostname
        start_time = time()
        hostname = gethostname()
        
        # Lock file
        lock_file = Path(tempdir()) * "/syncb.lock"
        
        new(config, logger, symb_links_manager, modo, dry_run, delete, yes, overwrite, 
            backup_dir_mode, verbose, use_checksum, bw_limit, timeout_minutes,
            items_especificos, exclusiones_cli, sync_crypto,
            elementos_procesados, errores_sincronizacion, archivos_transferidos,
            archivos_borrados, archivos_crypto_transferidos,
            start_time, hostname, lock_file)
    end
end


function run(app::SyncBidireccional)
    try
        # Parsear argumentos
        parse_arguments(app)
        
        # Mostrar banner
        mostrar_banner(app)
        
        # Establecer lock
        if !establecer_lock(app)
            return 1
        end
        
        # Verificar dependencias
        if !verificar_rsync()
            return 1
        end
        
        # Verificaciones
        if !verificar_pcloud_montado(app)
            return 1
        end
        
        # Confirmar ejecución
        if !confirmar_ejecucion(app)
            return 0
        end
        
        # Procesar elementos
        exit_code = procesar_elementos(app)
        
        # Sincronizar Crypto si está habilitado
        if app.sync_crypto
            if !sincronizar_crypto(app)
                exit_code = 1
            end
        end
        
        # Ajustar permisos
        if app.modo == "bajar"
            ajustar_permisos_ejecutables(app)
        end
        
        # Manejar enlaces simbólicos
        if !manejar_enlaces_simbolicos(app)
            exit_code = 1
        end
        
        # Mostrar estadísticas
        mostrar_estadisticas(app)
        
        return exit_code
        
    catch e
        if isa(e, InterruptException)
            log_info(app.logger, "Operación cancelada por el usuario")
            return 1
        else
            log_error(app.logger, "Error inesperado: $e")
            return 1
        end
    finally
        # Limpieza
        eliminar_lock(app)
        close_logger(app.logger)
    end
end

function parse_arguments(app::SyncBidireccional)
    parser = ArgParseSettings(
        description="Sincronización bidireccional entre directorio local y pCloud",
        epilog="""
        Ejemplos:
          syncb.jl --subir
          syncb.jl --bajar --dry-run
          syncb.jl --subir --delete --yes
          syncb.jl --subir --item documentos/
          syncb.jl --bajar --item configuracion.ini --item .local/bin --dry-run
          syncb.jl --subir --crypto
        """,
        add_help=true
    )
    
    @add_arg_table! parser begin
        "--subir"
            help = "Sincroniza desde local a pCloud"
            action = :store_true
        "--bajar"
            help = "Sincroniza desde pCloud a local"
            action = :store_true
        "--delete"
            help = "Elimina archivos obsoletos en destino"
            action = :store_true
        "--dry-run"
            help = "Simula sin hacer cambios reales"
            action = :store_true
        "--item"
            help = "Sincroniza solo el elemento especificado"
            action = :append_arg
            nargs = 1
        "--exclude"
            help = "Excluye archivos que coincidan con el patrón"
            action = :append_arg
            nargs = 1
        "--yes"
            help = "Ejecuta sin confirmación"
            action = :store_true
        "--backup-dir"
            help = "Usa directorio de backup de solo lectura"
            action = :store_true
        "--overwrite"
            help = "Sobrescribe todos los archivos en destino"
            action = :store_true
        "--checksum"
            help = "Fuerza comparación con checksum"
            action = :store_true
        "--bwlimit"
            help = "Limita la velocidad de transferencia (KB/s)"
            arg_type = Int
        "--timeout"
            help = "Límite de tiempo por operación (minutos)"
            arg_type = Int
            default = 30
        "--force-unlock"
            help = "Fuerza eliminación de lock"
            action = :store_true
        "--crypto"
            help = "Incluye la sincronización del directorio Crypto"
            action = :store_true
        "--verbose"
            help = "Habilita modo verboso"
            action = :store_true
        "--test"
            help = "Ejecuta tests unitarios"
            action = :store_true
        "--config"
            help = "Ruta al archivo de configuración TOML"
    end
    
    args = parse_args(parser)
    
    # Asignar valores
    if args["subir"]
        app.modo = "subir"
    elseif args["bajar"]
        app.modo = "bajar"
    end
    
    app.dry_run = args["dry-run"]
    app.delete = args["delete"]
    app.yes = args["yes"]
    app.overwrite = args["overwrite"]
    app.use_checksum = args["checksum"]
    app.bw_limit = args["bwlimit"]
    app.timeout_minutes = args["timeout"]
    app.verbose = args["verbose"]
    app.sync_crypto = args["crypto"]
    
    if args["item"] !== nothing
        app.items_especificos = args["item"]
    end
    
    if args["exclude"] !== nothing
        app.exclusiones_cli = args["exclude"]
    end
    
    if args["backup-dir"]
        app.backup_dir_mode = "readonly"
    end
    
    # Manejar opciones especiales
    if args["force-unlock"]
        force_unlock(app)
    end
    
    if args["test"]
        run_tests(app)
    end
    
    return args
end

function force_unlock(app::SyncBidireccional)
    if isfile(app.lock_file)
        rm(app.lock_file)
        log_info(app.logger, "Lock eliminado forzosamente")
    else
        log_info(app.logger, "No existe archivo de lock")
    end
end

function run_tests(app::SyncBidireccional)
    # Implementar tests
    println("Ejecutando tests unitarios...")
end

function mostrar_banner(app::SyncBidireccional)
    pcloud_dir = get_pcloud_dir(app)
    
    println("=" ^ 50)
    if app.modo == "subir"
        println("MODO: SUBIR (Local → pCloud)")
        println("ORIGEN: $(app.config.LOCAL_DIR)")
        println("DESTINO: $pcloud_dir")
    else
        println("MODO: BAJAR (pCloud → Local)")
        println("ORIGEN: $pcloud_dir")
        println("DESTINO: $(app.config.LOCAL_DIR)")
    end
    
    if app.backup_dir_mode == "readonly"
        println("DIRECTORIO: Backup de solo lectura (pCloud Backup)")
    else
        println("DIRECTORIO: Backup común (Backup_Comun)")
    end
    
    if app.dry_run
        println("ESTADO: MODO SIMULACIÓN (no se realizarán cambios)")
    end
    
    # ... resto del banner similar al Python
end

function establecer_lock(app::SyncBidireccional)
    # Implementar lógica de lock file
    true
end

function verificar_rsync()
    try
        read(`which rsync`, String)
        return true
    catch
        @error "rsync no está instalado"
        return false
    end
end

function verificar_pcloud_montado(app::SyncBidireccional)
    pcloud_dir = get_pcloud_dir(app)
    
    if !isdir(app.config.PCLOUD_MOUNT_POINT)
        log_error(app.logger, "El punto de montaje de pCloud no existe: $(app.config.PCLOUD_MOUNT_POINT)")
        return false
    end
    
    # ... resto de verificaciones similares al Python
    true
end

function confirmar_ejecucion(app::SyncBidireccional)
    if app.yes
        return true
    end
    
    print("¿Desea continuar con la sincronización? [s/N]: ")
    respuesta = readline()
    return lowercase(respuesta) in ["s", "si", "sí", "y", "yes"]
end

function get_pcloud_dir(app::SyncBidireccional)
    if app.backup_dir_mode == "readonly"
        return app.config.PCLOUD_BACKUP_READONLY
    else
        return app.config.PCLOUD_BACKUP_COMUN
    end
end

function get_lista_sincronizacion(app::SyncBidireccional)
    if !isempty(app.items_especificos)
        return app.items_especificos
    end
    
    if app.hostname == app.config.hostname_rtva
        host_specific = get(app.config.data, "host_specific", Dict())
        if haskey(host_specific, app.hostname)
            return get(host_specific[app.hostname], "directorios_sincronizacion", [])
        end
    end
    
    return app.config.directorios_sincronizacion
end

function procesar_elementos(app::SyncBidireccional)
    elementos = get_lista_sincronizacion(app)
    exit_code = 0
    
    for elemento in elementos
        if !sincronizar_elemento(app, elemento)
            exit_code = 1
        end
        println("-" ^ 50)
    end
    
    return exit_code
end

function sincronizar_elemento(app::SyncBidireccional, elemento::String)
    pcloud_dir = get_pcloud_dir(app)
    
    if app.modo == "subir"
        origen = app.config.LOCAL_DIR / elemento
        destino = pcloud_dir / elemento
        direccion = "LOCAL → PCLOUD (Subir)"
    else
        origen = pcloud_dir / elemento
        destino = app.config.LOCAL_DIR / elemento
        direccion = "PCLOUD → LOCAL (Bajar)"
    end
    
    if !exists(origen)
        log_warn(app.logger, "No existe $origen")
        return false
    end
    
    # Construir comando rsync
    cmd = construir_comando_rsync(app, origen, destino)
    
    try
        log_debug(app.logger, "Ejecutando: $cmd")
        
        if app.dry_run
            result = run(cmd; wait=true)
            if result.exitcode == 0
                log_success(app.logger, "Sincronización completada: $elemento")
                return true
            else
                log_error(app.logger, "Error en simulación: $elemento")
                return false
            end
        else
            result = run(cmd; wait=true)
            if result.exitcode == 0
                log_success(app.logger, "Sincronización completada: $elemento")
                return true
            else
                log_error(app.logger, "Error en sincronización: $elemento")
                app.errores_sincronizacion += 1
                return false
            end
        end
    catch e
        log_error(app.logger, "Error ejecutando rsync: $e")
        app.errores_sincronizacion += 1
        return false
    end
end

function construir_comando_rsync(app::SyncBidireccional, origen::AbstractPath, destino::AbstractPath)
    opts = ["-av"]
    
    if !app.overwrite
        push!(opts, "--update")
    end
    
    if app.dry_run
        push!(opts, "--dry-run")
    end
    
    if app.delete
        push!(opts, "--delete")
    end
    
    if app.use_checksum
        push!(opts, "--checksum")
    end
    
    if app.bw_limit !== nothing
        push!(opts, "--bwlimit=$(app.bw_limit)")
    end
    
    # Añadir exclusiones
    exclusiones = vcat(app.config.exclusiones, app.exclusiones_cli)
    for patron in exclusiones
        push!(opts, "--exclude=$patron")
    end
    
    return `rsync $opts $origen $destino`
end

function sincronizar_crypto(app::SyncBidireccional)
    # Implementar sincronización Crypto similar al Python
    true
end

function manejar_enlaces_simbolicos(app::SyncBidireccional)
    if app.modo == "subir"
        return generar_archivo_enlaces(app.symb_links_manager, get_lista_sincronizacion(app), app.dry_run)
    else
        return recrear_enlaces_desde_archivo(app.symb_links_manager, app.dry_run)
    end
end

function ajustar_permisos_ejecutables(app::SyncBidireccional)
    for patron in app.config.permisos_files
        # Implementar lógica de ajuste de permisos
    end
end

function mostrar_estadisticas(app::SyncBidireccional)
    tiempo_total = time() - app.start_time
    # ... similar al Python
end

function eliminar_lock(app::SyncBidireccional)
    if isfile(app.lock_file)
        rm(app.lock_file)
    end
end

#?end # module SyncBidireccionalModule
