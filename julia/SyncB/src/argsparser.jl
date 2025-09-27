
using ArgParse

export parse_arguments

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

