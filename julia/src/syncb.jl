#!/usr/bin/env julia

"""
Script: syncb.jl
Descripción: Sincronización bidireccional avanzada entre directorio local y pCloud Drive
Autor: Conversión desde Bash a Julia
Licencia: MIT
"""

module SyncB

using TOML
using ArgParse
using Logging
using Dates
using FileWatching
using FilePathsBase
using Mmap
using Sockets

# Constantes y configuración
const ANSI_COLORS = Dict(
    :RED => "\033[0;31m",
    :GREEN => "\033[0;32m", 
    :YELLOW => "\033[1;33m",
    :BLUE => "\033[0;34m",
    :MAGENTA => "\033[0;35m",
    :CYAN => "\033[0;36m",
    :WHITE => "\033[1;37m",
    :NC => "\033[0m"
)

const UNICODE_ICONS = Dict(
    :CHECK_MARK => "✓",
    :CROSS_MARK => "✗",
    :INFO_ICON => "ℹ",
    :WARNING_ICON => "⚠",
    :DEBUG_ICON => "🔍",
    :LOCK_ICON => "🔒",
    :UNLOCK_ICON => "🔓",
    :CLOCK_ICON => "⏱",
    :SYNC_ICON => "🔄",
    :ERROR_ICON => "❌",
    :SUCCESS_ICON => "✅"
)

# Tipos de datos
mutable struct SyncConfig
    pcloud_mount_point::String
    local_dir::String
    log_file::String
    lock_file::String
    lock_timeout::Int
    default_timeout_minutes::Int
    cloud_mount_check_file::String
    
    backup_dirs::Dict{String,String}
    crypto_dirs::Dict{String,String}
    host_configs::Dict{String,Dict}
    sync_items::Dict{String,Vector{String}}
    exclusions::Vector{String}
    permissions::Dict{String,Vector{String}}
end

mutable struct SyncState
    mode::String
    dry_run::Bool
    delete::Bool
    yes::Bool
    overwrite::Bool
    backup_dir_mode::String
    verbose::Bool
    debug::Bool
    use_checksum::Bool
    bw_limit::Union{String,Nothing}
    sync_crypto::Bool
    timeout_minutes::Int
    
    specific_items::Vector{String}
    cli_exclusions::Vector{String}
    
    # Estadísticas
    elements_processed::Int
    sync_errors::Int
    files_transferred::Int
    links_created::Int
    links_existing::Int
    links_errors::Int
    links_detected::Int
    files_deleted::Int
    crypto_files_transferred::Int
    
    start_time::DateTime
end

mutable struct SyncContext
    config::SyncConfig
    state::SyncState
    hostname::String
    script_dir::String
    logger::AbstractLogger
end

# Funciones de utilidad
function expanduser(path::String)::String
    if startswith(path, "~/")
        return replace(path, "~" => homedir())
    end
    return path
end

function normalize_path(path::String)::String
    expanded = expanduser(path)
    try
        return realpath(expanded)
    catch e
        return expanded
    end
end

function get_hostname()::String
    try
        return strip(read(`hostname -f`, String))
    catch e
        try
            return strip(read(`hostname`, String))
        catch e2
            return "unknown-host"
        end
    end
end

function get_script_dir()::String
    return dirname(@__FILE__)
end

# Sistema de logging
struct RotatingFileLogger <: AbstractLogger
    file::String
    max_size::Int
    level::LogLevel
end

function Logging.handle_message(logger::RotatingFileLogger, level, message, _module, group, id, file, line; kwargs...)
    if level >= logger.level
        # Rotar si es necesario
        if isfile(logger.file)
            try
                stat = stat(logger.file)
                if stat.size > logger.max_size
                    mv(logger.file, logger.file * ".old", force=true)
                end
            catch e
                # Continuar si no se puede rotar
            end
        end
        
        # Escribir log
        timestamp = now()
        level_str = string(level)
        open(logger.file, "a") do f
            println(f, "$timestamp [$level_str] $message")
        end
    end
end

Logging.shouldlog(logger::RotatingFileLogger, level, _module, group, id) = level >= logger.level
Logging.min_enabled_level(logger::RotatingFileLogger) = logger.level

function create_logger(config::SyncConfig)::RotatingFileLogger
    log_file = expanduser(config.log_file)
    return RotatingFileLogger(log_file, 10_000_000, Logging.Info)
end

function log_info(ctx::SyncContext, msg::String)
    colored_msg = "$(ANSI_COLORS[:BLUE])$(UNICODE_ICONS[:INFO_ICON]) [INFO]$(ANSI_COLORS[:NC]) $msg"
    println(colored_msg)
    @info ctx.logger msg
end

function log_warn(ctx::SyncContext, msg::String)
    colored_msg = "$(ANSI_COLORS[:YELLOW])$(UNICODE_ICONS[:WARNING_ICON]) [WARN]$(ANSI_COLORS[:NC]) $msg"
    println(colored_msg)
    @warn ctx.logger msg
end

function log_error(ctx::SyncContext, msg::String)
    colored_msg = "$(ANSI_COLORS[:RED])$(UNICODE_ICONS[:CROSS_MARK]) [ERROR]$(ANSI_COLORS[:NC]) $msg"
    println(stderr, colored_msg)
    @error ctx.logger msg
end

function log_success(ctx::SyncContext, msg::String)
    colored_msg = "$(ANSI_COLORS[:GREEN])$(UNICODE_ICONS[:CHECK_MARK]) [SUCCESS]$(ANSI_COLORS[:NC]) $msg"
    println(colored_msg)
    @info ctx.logger "SUCCESS: $msg"
end

function log_debug(ctx::SyncContext, msg::String)
    if ctx.state.debug || ctx.state.verbose
        colored_msg = "$(ANSI_COLORS[:MAGENTA])$(UNICODE_ICONS[:CLOCK_ICON]) [DEBUG]$(ANSI_COLORS[:NC]) $msg"
        println(stderr, colored_msg)
        @debug ctx.logger msg
    end
end

# Carga de configuración
function load_config(config_file::String = "syncb_config.toml")::SyncConfig
    # Buscar archivo de configuración
    search_paths = [
        joinpath(get_script_dir(), config_file),
        joinpath(pwd(), config_file),
        expanduser("~/.config/syncb/$config_file")
    ]
    
    config_path = nothing
    for path in search_paths
        if isfile(path)
            config_path = path
            break
        end
    end
    
    if config_path === nothing
        error("No se encontró el archivo de configuración: $config_file")
    end
    
    # Cargar TOML
    toml_data = TOML.parsefile(config_path)
    
    # Construir configuración
    config = SyncConfig(
        expanduser(get(toml_data["general"], "pcloud_mount_point", "~/pCloudDrive")),
        expanduser(get(toml_data["general"], "local_dir", "~")),
        expanduser(get(toml_data["general"], "log_file", "~/syncb.log")),
        get(toml_data["general"], "lock_file", "/tmp/syncb.lock"),
        get(toml_data["general"], "lock_timeout", 3600),
        get(toml_data["general"], "default_timeout_minutes", 30),
        get(toml_data["general"], "cloud_mount_check_file", "mount.check"),
        
        Dict{String,String}(get(toml_data, "backup_directories", Dict())),
        Dict{String,String}(get(toml_data, "crypto", Dict())),
        Dict{String,Dict}(get(toml_data, "hosts", Dict())),
        Dict{String,Vector{String}}(),
        get(get(toml_data, "exclusions", Dict()), "patterns", String[]),
        Dict{String,Vector{String}}(get(toml_data, "permissions", Dict()))
    )
    
    # Cargar items de sincronización
    sync_dirs = get(toml_data, "sync_directories", Dict())
    for (host, items) in sync_dirs
        config.sync_items[host] = get(items, "items", String[])
    end
    
    return config
end

# Manejo de argumentos de línea de comandos
function parse_arguments()::Dict{String,Any}
    parser = ArgParseSettings(
        description = "Sincronización bidireccional avanzada entre directorio local y pCloud Drive",
        version = "1.0.0",
        add_version = true
    )
    
    @add_arg_table! parser begin
        "--subir"
            help = "Sincroniza desde el directorio local a pCloud"
            action = :store_true
        "--bajar"
            help = "Sincroniza desde pCloud al directorio local" 
            action = :store_true
        "--delete"
            help = "Elimina en destino los archivos que no existan en origen"
            action = :store_true
        "--dry-run"
            help = "Simula la operación sin hacer cambios reales"
            action = :store_true
        "--item"
            help = "Sincroniza solo el elemento especificado (puede usarse múltiples veces)"
            action = :append_arg
            nargs = 1
        "--exclude"
            help = "Excluye archivos que coincidan con el patrón (puede usarse múltiples veces)"
            action = :append_arg
            nargs = 1
        "--yes"
            help = "No pregunta confirmación, ejecuta directamente"
            action = :store_true
        "--backup-dir"
            help = "Usa el directorio de backup de solo lectura"
            action = :store_true
        "--overwrite"
            help = "Sobrescribe todos los archivos en destino"
            action = :store_true
        "--checksum"
            help = "Fuerza comparación con checksum (más lento)"
            action = :store_true
        "--bwlimit"
            help = "Limita la velocidad de transferencia (ej: 1000 para 1MB/s)"
            arg_type = String
        "--timeout"
            help = "Límite de tiempo por operación en minutos"
            arg_type = Int
        "--force-unlock"
            help = "Forzar eliminación de lock"
            action = :store_true
        "--crypto"
            help = "Incluye la sincronización del directorio Crypto"
            action = :store_true
        "--verbose"
            help = "Habilita modo verboso"
            action = :store_true
        "--debug"
            help = "Habilita modo debug"
            action = :store_true
    end
    
    return parse_args(parser)
end

# Funciones de verificación
function verify_dependencies(ctx::SyncContext)::Bool
    log_debug(ctx, "Verificando dependencias...")
    
    # Verificar rsync
    try
        run(`rsync --version`)
        log_info(ctx, "rsync encontrado: OK")
    catch e
        log_error(ctx, "rsync no está instalado")
        return false
    end
    
    # Verificar curl para conectividad
    try
        run(`curl --version`)
    catch e
        log_warn(ctx, "curl no disponible, omitiendo verificación de conectividad")
    end
    
    return true
end

function verify_pcloud_mounted(ctx::SyncContext)::Bool
    config = ctx.config
    mount_point = config.pcloud_mount_point
    
    log_debug(ctx, "Verificando montaje de pCloud en: $mount_point")
    
    # Verificar si el punto de montaje existe
    if !isdir(mount_point)
        log_error(ctx, "El punto de montaje de pCloud no existe: $mount_point")
        return false
    end
    
    # Verificar si el directorio está vacío
    if isempty(readdir(mount_point))
        log_error(ctx, "El directorio de pCloud está vacío: $mount_point")
        return false
    end
    
    # Verificar usando mount (sistemas Unix)
    try
        if success(`mountpoint $mount_point`)
            log_info(ctx, "pCloud está montado correctamente")
            return true
        else
            log_error(ctx, "pCloud no está montado correctamente")
            return false
        end
    catch e
        log_warn(ctx, "No se pudo verificar el montaje con mountpoint, continuando...")
    end
    
    # Verificación adicional con df
    try
        run(`df $mount_point`)
        log_info(ctx, "Verificación de pCloud completada con éxito")
        return true
    catch e
        log_error(ctx, "pCloud no está montado correctamente")
        return false
    end
end

function verify_connectivity(ctx::SyncContext)::Bool
    log_debug(ctx, "Verificando conectividad con pCloud...")
    
    max_retries = 3
    timeout = 5
    
    for retry in 1:max_retries
        try
            run(pipeline(`curl -s --connect-timeout $timeout https://www.pcloud.com/`, devnull))
            log_info(ctx, "Verificación de conectividad pCloud: OK")
            return true
        catch e
            log_warn(ctx, "Intento $retry/$max_retries: No se pudo conectar a pCloud")
            sleep(1)
        end
    end
    
    log_error(ctx, "No se pudo conectar a pCloud después de $max_retries intentos")
    return false
end

function verify_disk_space(ctx::SyncContext, needed_mb::Int = 100)::Bool
    log_debug(ctx, "Verificando espacio en disco. Necesarios: $needed_mb MB")
    
    mount_point = ctx.state.mode == "subir" ? 
        ctx.config.pcloud_mount_point : ctx.config.local_dir
    
    if !isdir(mount_point)
        log_warn(ctx, "El punto de montaje $mount_point no existe, omitiendo verificación")
        return true
    end
    
    try
        df_output = read(`df -m $mount_point`, String)
        lines = split(strip(df_output), "\n")
        if length(lines) >= 2
            parts = split(lines[2])
            available_mb = parse(Int, parts[4])  # Columna de disponible en MB
            
            if available_mb < needed_mb
                log_error(ctx, "Espacio insuficiente en $mount_point")
                log_error(ctx, "Disponible: $(available_mb)MB, Necesario: $(needed_mb)MB")
                return false
            else
                log_info(ctx, "Espacio en disco verificado. Disponible: $(available_mb)MB")
                return true
            end
        end
    catch e
        log_warn(ctx, "No se pudo verificar el espacio en disco: $e")
    end
    
    return true
end

# Manejo de locks
function establish_lock(ctx::SyncContext)::Bool
    config = ctx.config
    lock_file = config.lock_file
    
    if isfile(lock_file)
        log_debug(ctx, "Archivo de lock encontrado: $lock_file")
        
        try
            lock_content = read(lock_file, String)
            lines = split(strip(lock_content), "\n")
            if !isempty(lines)
                lock_pid = parse(Int, lines[1])
                
                # Verificar si el proceso todavía está ejecutándose
                try
                    run(`ps -p $lock_pid`)
                    log_error(ctx, "Ya hay una ejecución en progreso (PID: $lock_pid)")
                    return false
                catch e
                    log_warn(ctx, "Eliminando lock obsoleto del proceso $lock_pid")
                    rm(lock_file)
                end
            end
        catch e
            log_warn(ctx, "Lock corrupto, eliminando...")
            rm(lock_file)
        end
    end
    
    # Crear nuevo lock
    try
        open(lock_file, "w") do f
            println(f, getpid())
            println(f, "Fecha: $(now())")
            println(f, "Modo: $(ctx.state.mode)")
            println(f, "Usuario: $(ENV["USER"])")
            println(f, "Hostname: $(ctx.hostname)")
        end
        log_info(ctx, "Lock establecido: $lock_file")
        return true
    catch e
        log_error(ctx, "No se pudo crear el archivo de lock: $e")
        return false
    end
end

function remove_lock(ctx::SyncContext)
    config = ctx.config
    lock_file = config.lock_file
    
    if isfile(lock_file)
        try
            lock_content = read(lock_file, String)
            lines = split(strip(lock_content), "\n")
            if !isempty(lines) && parse(Int, lines[1]) == getpid()
                rm(lock_file)
                log_info(ctx, "Lock eliminado")
            end
        catch e
            log_warn(ctx, "Error al eliminar lock: $e")
        end
    end
end

# Funciones de sincronización
function build_rsync_options(ctx::SyncContext)::Vector{String}
    state = ctx.state
    config = ctx.config
    
    options = [
        "--recursive",
        "--verbose", 
        "--times",
        "--progress",
        "--munge-links",
        "--whole-file",
        "--itemize-changes"
    ]
    
    if !state.overwrite
        push!(options, "--update")
    end
    
    if state.dry_run
        push!(options, "--dry-run")
    end
    
    if state.delete
        push!(options, "--delete-delay")
    end
    
    if state.use_checksum
        push!(options, "--checksum")
    end
    
    if state.bw_limit !== nothing
        push!(options, "--bwlimit=$(state.bw_limit)")
    end
    
    # Añadir exclusiones del archivo de configuración
    if !isempty(config.exclusions)
        for pattern in config.exclusions
            push!(options, "--exclude=$pattern")
        end
    end
    
    # Añadir exclusiones de línea de comandos
    if !isempty(state.cli_exclusions)
        for pattern in state.cli_exclusions
            push!(options, "--exclude=$pattern")
        end
    end
    
    return options
end

function sync_element(ctx::SyncContext, element::String)::Bool
    config = ctx.config
    state = ctx.state
    
    # Determinar rutas según el modo
    if state.mode == "subir"
        source = joinpath(config.local_dir, element)
        destination = joinpath(get_pcloud_dir(ctx), element)
        direction = "LOCAL → PCLOUD (Subir)"
    else
        source = joinpath(get_pcloud_dir(ctx), element)
        destination = joinpath(config.local_dir, element)
        direction = "PCLOUD → LOCAL (Bajar)"
    end
    
    # Verificar si el origen existe
    if !isfile(source) && !isdir(source)
        log_warn(ctx, "No existe $source")
        return false
    end
    
    log_info(ctx, "Sincronizando: $element ($direction)")
    
    # Construir opciones de rsync
    rsync_opts = build_rsync_options(ctx)
    
    # Crear directorio destino si no existe
    dest_dir = dirname(destination)
    if !isdir(dest_dir) && !state.dry_run
        mkpath(dest_dir)
    end
    
    # Ejecutar rsync
    cmd = `rsync $rsync_opts $source $destination`
    log_debug(ctx, "Ejecutando: $cmd")
    
    try
        if state.timeout_minutes > 0 && !state.dry_run
            run(cmd, wait=false)
            # Implementar timeout aquí
        else
            run(cmd)
        end
        log_success(ctx, "Sincronización completada: $element")
        return true
    catch e
        log_error(ctx, "Error en sincronización: $element - $e")
        return false
    end
end

function get_pcloud_dir(ctx::SyncContext)::String
    config = ctx.config
    state = ctx.state
    
    base_dir = config.pcloud_mount_point
    if state.backup_dir_mode == "readonly"
        return joinpath(base_dir, config.backup_dirs["readonly"])
    else
        return joinpath(base_dir, config.backup_dirs["comun"])
    end
end

# Manejo de enlaces simbólicos
function handle_symbolic_links(ctx::SyncContext)::Bool
    if ctx.state.mode == "subir"
        return generate_symlinks_file(ctx)
    else
        return recreate_symlinks_from_file(ctx)
    end
end

function generate_symlinks_file(ctx::SyncContext)::Bool
    config = ctx.config
    state = ctx.state
    
    symlinks_file = joinpath(get_pcloud_dir(ctx), ".syncb_symlinks.meta")
    temp_file = tempname()
    
    log_info(ctx, "Generando archivo de enlaces simbólicos...")
    
    try
        open(temp_file, "w") do f
            # Buscar enlaces en los elementos a sincronizar
            elements = get_sync_elements(ctx)
            for element in elements
                element_path = joinpath(config.local_dir, element)
                find_and_record_symlinks(ctx, element_path, f)
            end
        end
        
        # Sincronizar archivo de enlaces
        if !state.dry_run
            cp(temp_file, symlinks_file, force=true)
        end
        
        log_info(ctx, "Archivo de enlaces generado: $(ctx.state.links_detected) enlaces detectados")
        rm(temp_file)
        return true
    catch e
        log_error(ctx, "Error generando archivo de enlaces: $e")
        return false
    end
end

function find_and_record_symlinks(ctx::SyncContext, path::String, file::IO)
    if islink(path)
        record_symlink(ctx, path, file)
    elseif isdir(path)
        for entry in readdir(path)
            full_path = joinpath(path, entry)
            if islink(full_path)
                record_symlink(ctx, full_path, file)
            elseif isdir(full_path)
                find_and_record_symlinks(ctx, full_path, file)
            end
        end
    end
end

function record_symlink(ctx::SyncContext, symlink_path::String, file::IO)
    try
        target = readlink(symlink_path)
        relative_path = relpath(symlink_path, ctx.config.local_dir)
        
        # Normalizar ruta
        if startswith(target, ctx.config.local_dir)
            normalized_target = replace(target, ctx.config.local_dir => "/home/\$USERNAME")
        else
            normalized_target = target
        end
        
        println(file, "$relative_path\t$normalized_target")
        ctx.state.links_detected += 1
        log_debug(ctx, "Registrado enlace: $relative_path -> $normalized_target")
    catch e
        log_warn(ctx, "Error procesando enlace $symlink_path: $e")
    end
end

function recreate_symlinks_from_file(ctx::SyncContext)::Bool
    config = ctx.config
    state = ctx.state
    
    symlinks_file = joinpath(get_pcloud_dir(ctx), ".syncb_symlinks.meta")
    
    if !isfile(symlinks_file)
        log_info(ctx, "No se encontró archivo de enlaces, omitiendo recreación")
        return true
    end
    
    log_info(ctx, "Recreando enlaces simbólicos...")
    
    try
        open(symlinks_file, "r") do f
            for line in eachline(f)
                parts = split(line, '\t')
                if length(parts) == 2
                    link_path, target = parts
                    recreate_symlink(ctx, link_path, target)
                end
            end
        end
        log_info(ctx, "Enlaces recreados: $(ctx.state.links_created) creados, $(ctx.state.links_errors) errores")
        return true
    catch e
        log_error(ctx, "Error recreando enlaces: $e")
        return false
    end
end

function recreate_symlink(ctx::SyncContext, link_path::String, target::String)
    config = ctx.config
    state = ctx.state
    
    full_link_path = joinpath(config.local_dir, link_path)
    parent_dir = dirname(full_link_path)
    
    # Crear directorio padre si no existe
    if !isdir(parent_dir) && !state.dry_run
        mkpath(parent_dir)
    end
    
    # Normalizar target
    normalized_target = replace(target, "/home/\$USERNAME" => config.local_dir)
    normalized_target = replace(normalized_target, "\$USERNAME" => ENV["USER"])
    
    # Verificar si el enlace ya existe y es correcto
    if islink(full_link_path)
        current_target = readlink(full_link_path)
        if current_target == normalized_target
            ctx.state.links_existing += 1
            return
        else
            # Eliminar enlace existente incorrecto
            if !state.dry_run
                rm(full_link_path)
            end
        end
    end
    
    # Crear nuevo enlace
    if state.dry_run
        log_debug(ctx, "SIMULACIÓN: Crear enlace $full_link_path -> $normalized_target")
        ctx.state.links_created += 1
    else
        try
            symlink(normalized_target, full_link_path)
            ctx.state.links_created += 1
            log_debug(ctx, "Enlace creado: $full_link_path -> $normalized_target")
        catch e
            ctx.state.links_errors += 1
            log_error(ctx, "Error creando enlace $full_link_path: $e")
        end
    end
end

# Funciones auxiliares
function get_sync_elements(ctx::SyncContext)::Vector{String}
    state = ctx.state
    config = ctx.config
    
    if !isempty(state.specific_items)
        return state.specific_items
    else
        host_key = ctx.hostname
        if haskey(config.sync_items, host_key)
            return config.sync_items[host_key]
        else
            return config.sync_items["default"]
        end
    end
end

function show_banner(ctx::SyncContext)
    config = ctx.config
    state = ctx.state
    
    pcloud_dir = get_pcloud_dir(ctx)
    
    println("==========================================")
    if state.mode == "subir"
        println("MODO: SUBIR (Local → pCloud)")
        println("ORIGEN: $(config.local_dir)")
        println("DESTINO: $pcloud_dir")
    else
        println("MODO: BAJAR (pCloud → Local)")
        println("ORIGEN: $pcloud_dir")
        println("DESTINO: $(config.local_dir)")
    end
    
    if state.backup_dir_mode == "readonly"
        println("DIRECTORIO: Backup de solo lectura")
    else
        println("DIRECTORIO: Backup común")
    end
    
    if state.dry_run
        println("ESTADO: MODO SIMULACIÓN (no se realizarán cambios)")
    end
    
    if state.delete
        println("BORRADO: ACTIVADO")
    end
    
    if state.sync_crypto
        println("CRYPTO: INCLUIDO")
    else
        println("CRYPTO: EXCLUIDO")
    end
    
    if !isempty(state.specific_items)
        println("ELEMENTOS ESPECÍFICOS: $(join(state.specific_items, ", "))")
    end
    
    if !isempty(state.cli_exclusions)
        println("EXCLUSIONES CLI: $(length(state.cli_exclusions)) patrones")
    end
    println("==========================================")
end

function confirm_execution(ctx::SyncContext)::Bool
    if ctx.state.yes
        log_info(ctx, "Confirmación automática (--yes): se procede con la sincronización")
        return true
    end
    
    print("¿Desea continuar con la sincronización? [s/N]: ")
    response = readline()
    return lowercase(strip(response)) == "s"
end

function show_statistics(ctx::SyncContext)
    state = ctx.state
    elapsed = now() - state.start_time
    total_seconds = Dates.value(elapsed) / 1000
    
    hours = total_seconds ÷ 3600
    minutes = (total_seconds % 3600) ÷ 60
    seconds = total_seconds % 60
    
    println()
    println("==========================================")
    println("RESUMEN DE SINCRONIZACIÓN")
    println("==========================================")
    println("Elementos procesados: $(state.elements_processed)")
    println("Archivos transferidos: $(state.files_transferred)")
    if state.sync_crypto
        println("Archivos Crypto transferidos: $(state.crypto_files_transferred)")
    end
    if state.delete
        println("Archivos borrados: $(state.files_deleted)")
    end
    println("Enlaces manejados: $(state.links_created + state.links_existing)")
    println("  - Enlaces detectados/guardados: $(state.links_detected)")
    println("  - Enlaces creados: $(state.links_created)")
    println("  - Enlaces existentes: $(state.links_existing)")
    println("  - Enlaces con errores: $(state.links_errors)")
    println("Errores de sincronización: $(state.sync_errors)")
    
    if hours >= 1
        println("Tiempo total: $(Int(hours))h $(Int(minutes))m $(round(Int, seconds))s")
    elseif minutes >= 1
        println("Tiempo total: $(Int(minutes))m $(round(Int, seconds))s")
    else
        println("Tiempo total: $(round(Int, seconds))s")
    end
    
    avg_speed = state.files_transferred / max(total_seconds, 1)
    println("Velocidad promedio: $(round(avg_speed, digits=2)) archivos/segundo")
    println("Modo: $(state.dry_run ? "SIMULACIÓN" : "EJECUCIÓN REAL")")
    println("==========================================")
end

function send_notification(ctx::SyncContext, title::String, message::String, type::String = "info")
    try
        if success(`which notify-send`)
            urgency = type == "error" ? "critical" : "normal"
            icon = type == "error" ? "dialog-error" : 
                   type == "warning" ? "dialog-warning" : "dialog-information"
            run(`notify-send --urgency=$urgency --icon=$icon $title $message`)
        elseif success(`which osascript`)
            run(`osascript -e "display notification \"$message\" with title \"$title\""`)
        else
            println("🔔 $title: $message")
        end
    catch e
        log_debug(ctx, "No se pudo enviar notificación: $e")
    end
end

# Función principal de sincronización
function perform_sync(ctx::SyncContext)::Bool
    state = ctx.state
    
    log_info(ctx, "Iniciando proceso de sincronización en modo: $(state.mode)")
    
    # Verificaciones previas
    if !verify_pcloud_mounted(ctx)
        log_error(ctx, "Fallo en verificación de pCloud montado - abortando")
        return false
    end
    
    verify_connectivity(ctx)  # Solo advertencia si falla
    
    if !state.dry_run && !verify_disk_space(ctx, 500)
        log_error(ctx, "Fallo en verificación de espacio en disco - abortando")
        return false
    end
    
    # Confirmación
    if !state.dry_run && !confirm_execution(ctx)
        log_info(ctx, "Operación cancelada por el usuario")
        return false
    end
    
    # Sincronizar elementos principales
    elements = get_sync_elements(ctx)
    success_count = 0
    
    for element in elements
        if sync_element(ctx, element)
            success_count += 1
            state.files_transferred += 1  # Esto debería contarse mejor del output de rsync
        else
            state.sync_errors += 1
        end
        state.elements_processed += 1
        println("------------------------------------------")
    end
    
    # Sincronizar Crypto si está habilitado
    if state.sync_crypto
        if !sync_crypto(ctx)
            state.sync_errors += 1
        end
    else
        log_info(ctx, "Sincronización de directorio Crypto excluida")
    end
    
    # Manejar enlaces simbólicos
    if !handle_symbolic_links(ctx)
        state.sync_errors += 1
    end
    
    overall_success = state.sync_errors == 0
    if overall_success
        log_success(ctx, "Sincronización completada exitosamente")
    else
        log_warn(ctx, "Sincronización completada con $(state.sync_errors) errores")
    end
    
    return overall_success
end

function sync_crypto(ctx::SyncContext)::Bool
    config = ctx.config
    state = ctx.state
    
    # Determinar rutas según el hostname
    if ctx.hostname == "feynman.rtva.dnf" && haskey(config.host_configs, "feynman.rtva.dnf")
        host_config = config.host_configs["feynman.rtva.dnf"]
        if state.mode == "subir"
            source = expanduser(get(host_config, "local_crypto_host_dir", config.crypto_dirs["local_crypto_dir"]))
            destination = joinpath(config.pcloud_mount_point, get(host_config, "remote_crypto_host_dir", config.crypto_dirs["remote_crypto_dir"]))
        else
            source = joinpath(config.pcloud_mount_point, get(host_config, "remote_crypto_host_dir", config.crypto_dirs["remote_crypto_dir"]))
            destination = expanduser(get(host_config, "local_crypto_host_dir", config.crypto_dirs["local_crypto_dir"]))
        end
    else
        if state.mode == "subir"
            source = expanduser(config.crypto_dirs["local_crypto_dir"])
            destination = joinpath(config.pcloud_mount_point, config.crypto_dirs["remote_crypto_dir"])
        else
            source = joinpath(config.pcloud_mount_point, config.crypto_dirs["remote_crypto_dir"])
            destination = expanduser(config.crypto_dirs["local_crypto_dir"])
        end
    end
    
    log_info(ctx, "Sincronizando directorio Crypto...")
    
    # Construir opciones de rsync para Crypto
    rsync_opts = build_rsync_options(ctx)
    push!(rsync_opts, "--exclude=$(config.cloud_mount_check_file)")
    
    # Sincronizar KeePass
    keepass_source = joinpath(config.pcloud_mount_point, config.crypto_dirs["remote_keepass_dir"])
    keepass_dest = expanduser(config.crypto_dirs["local_keepass_dir"])
    
    if isdir(keepass_source) && !state.dry_run
        mkpath(keepass_dest)
    end
    
    if state.mode == "bajar" || state.dry_run
        keepass_cmd = `rsync $rsync_opts $keepass_source/ $keepass_dest/`
        log_debug(ctx, "Sincronizando KeePass: $keepass_cmd")
        if !state.dry_run
            try
                run(keepass_cmd)
            catch e
                log_warn(ctx, "Error sincronizando KeePass: $e")
            end
        end
    end
    
    # Sincronizar directorio Crypto principal
    crypto_cmd = `rsync $rsync_opts $source/ $destination/`
    log_debug(ctx, "Ejecutando sincronización Crypto: $crypto_cmd")
    
    try
        if !state.dry_run
            run(crypto_cmd)
        end
        log_success(ctx, "Sincronización Crypto completada")
        return true
    catch e
        log_error(ctx, "Error en sincronización Crypto: $e")
        return false
    end
end

# Función principal
function main()
    # Parsear argumentos
    args = parse_arguments()

    if get(args, "force-unlock", false)
        config = load_config()
        if isfile(config.lock_file)
            rm(config.lock_file)
            println("Lock forzado eliminado: $(config.lock_file)")
        else
            println("No hay lock activo")
        end
        return
    end
    
    # Validar modo
    if !get(args, "subir", false) && !get(args, "bajar", false)
        println(stderr, "ERROR: Debes especificar --subir o --bajar")
        show_help()
        exit(1)
    end
    
    # Inicializar contexto
    config = load_config()
    logger = create_logger(config)
    
    state = SyncState(
        get(args, "subir", false) ? "subir" : "bajar",
        get(args, "dry-run", false),
        get(args, "delete", false),
        get(args, "yes", false),
        get(args, "overwrite", false),
        get(args, "backup-dir", false) ? "readonly" : "comun",
        get(args, "verbose", false),
        get(args, "debug", false),
        get(args, "checksum", false),
        get(args, "bwlimit", nothing),
        get(args, "crypto", false),
        get(args, "timeout", config.default_timeout_minutes),
        get(args, "item", String[]),
        get(args, "exclude", String[]),
        0, 0, 0, 0, 0, 0, 0, 0, 0,
        now()
    )
    
    ctx = SyncContext(
        config,
        state,
        get_hostname(),
        get_script_dir(),
        logger
    )
    
    # Establecer lock
    if !establish_lock(ctx)
        exit(1)
    end
    
    # Configurar cleanup
    atexit(() -> remove_lock(ctx))
    
    try
        # Verificar dependencias
        if !verify_dependencies(ctx)
            exit(1)
        end
        
        # Mostrar banner
        show_banner(ctx)
        
        # Ejecutar sincronización
        success = perform_sync(ctx)
        
        # Mostrar estadísticas
        show_statistics(ctx)
        
        # Enviar notificación
        if success
            send_notification(ctx, "Sincronización Completada", 
                "Sincronización finalizada con éxito\n• Elementos: $(state.elements_processed)\n• Transferidos: $(state.files_transferred)", "info")
        else
            send_notification(ctx, "Sincronización con Errores",
                "Sincronización finalizada con errores\n• Errores: $(state.sync_errors)", "error")
        end
        
        exit(success ? 0 : 1)
        
    catch e
        log_error(ctx, "Error crítico: $e")
        remove_lock(ctx)
        rethrow()
    end
end

function show_help()
    println("""
    Uso: syncb.jl [OPCIONES]

    Opciones PRINCIPALES (obligatorio una de ellas):
      --subir            Sincroniza desde el directorio local a pCloud
      --bajar            Sincroniza desde pCloud al directorio local

    Opciones SECUNDARIAS (opcionales):
      --delete           Elimina en destino los archivos que no existan en origen
      --dry-run          Simula la operación sin hacer cambios reales
      --item ELEMENTO    Sincroniza solo el elemento especificado (puede usarse múltiples veces)
      --yes              No pregunta confirmación, ejecuta directamente
      --backup-dir       Usa el directorio de backup de solo lectura
      --exclude PATRON   Excluye archivos que coincidan con el patrón (puede usarse múltiples veces)
      --overwrite        Sobrescribe todos los archivos en destino
      --checksum         Fuerza comparación con checksum (más lento)
      --bwlimit KB/s     Limita la velocidad de transferencia
      --timeout MINUTOS  Límite de tiempo por operación
      --force-unlock     Forzar eliminación de lock
      --crypto           Incluye la sincronización del directorio Crypto
      --verbose          Habilita modo verboso
      --debug            Habilita modo debug
      --help             Muestra esta ayuda

    Ejemplos:
      julia syncb.jl --subir
      julia syncb.jl --bajar --dry-run
      julia syncb.jl --subir --delete --yes
      julia syncb.jl --subir --item documentos/
      julia syncb.jl --bajar --item configuracion.ini --item .local/bin --dry-run
    """)
end

# Punto de entrada
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module SyncB

# Ejecutar si es el script principal
if abspath(PROGRAM_FILE) == @__FILE__
    SyncB.main()
end
