#!/usr/bin/env julia

# Script: syncb.jl
# Descripción: Sincronización bidireccional entre directorio local y pCloud
# Uso:
#   Subir: ./syncb.jl --subir [--delete] [--dry-run] [--item elemento] [--yes] [--overwrite]
#   Bajar: ./syncb.jl --bajar [--delete] [--dry-run] [--item elemento] [--yes] [--backup-dir] [--overwrite]

using Pkg
using TOML
using Logging
using Dates
using ArgParse
using FilePathsBase
using FilePathsBase: exists, isdir, isfile, mkpath, stat, filesize
using Base.Filesystem: symlink, readlink, rm, mkdir, chmod

# Instalar paquetes requeridos automáticamente
const REQUIRED_PACKAGES = ["TOML", "ArgParse", "FilePathsBase"]

function install_required_packages()
    for pkg in REQUIRED_PACKAGES
        try
            @eval using $(Symbol(pkg))
        catch e
            @info "Instalando paquete: $pkg"
            Pkg.add(pkg)
            @eval using $(Symbol(pkg))
        end
    end
end

# Estructuras de datos
struct ConfigPaths
    local_dir::String
    pcloud_mount_point::String
    pcloud_backup_comun::String
    pcloud_backup_readonly::String
    config_search_paths::Vector{String}
end

struct ConfigFiles
    symlinks_file::String
    log_file::String
end

struct ConfigGeneral
    lock_timeout::Int
    hostname_rtva::String
    default_timeout_minutes::Int
end

struct ConfigColors
    red::String
    green::String
    yellow::String
    blue::String
    magenta::String
    cyan::String
    white::String
    no_color::String
end

struct ConfigIcons
    check_mark::String
    cross_mark::String
    info_icon::String
    warning_icon::String
    clock_icon::String
    sync_icon::String
    error_icon::String
    success_icon::String
end

struct ConfigLogging
    max_size_mb::Int
    backup_count::Int
end

struct ConfigNotifications
    enabled::Bool
end

struct ConfigPermisosEjecutables
    archivos::Vector{String}
end

struct SyncConfig
    paths::ConfigPaths
    files::ConfigFiles
    general::ConfigGeneral
    directorios_sincronizacion::Vector{String}
    exclusiones::Vector{String}
    host_specific::Dict{String,Any}
    permisos_ejecutables::ConfigPermisosEjecutables
    logging::ConfigLogging
    notifications::ConfigNotifications
    colors::ConfigColors
    icons::ConfigIcons
end

# Estado global de la aplicación
mutable struct AppState
    config::SyncConfig
    modo::String
    dry_run::Bool
    delete::Bool
    yes::Bool
    overwrite::Bool
    backup_dir_mode::String
    verbose::Bool
    debug::Bool
    use_checksum::Bool
    bw_limit::Union{String,Nothing}
    timeout_minutes::Int
    sync_crypto::Bool
    items_especificos::Vector{String}
    exclusiones_cli::Vector{String}
    elementos_procesados::Int
    errores_sincronizacion::Int
    archivos_transferidos::Int
    enlaces_creados::Int
    enlaces_existentes::Int
    enlaces_errores::Int
    enlaces_detectados::Int
    archivos_borrados::Int
    archivos_crypto_transferidos::Int
    start_time::DateTime
    lock_file::String
    temp_files::Vector{String}
end

# Constructor por defecto para AppState
function AppState(config::SyncConfig)
    AppState(
        config,
        "",                    # modo
        false,                 # dry_run
        false,                 # delete
        false,                 # yes
        false,                 # overwrite
        "comun",              # backup_dir_mode
        false,                 # verbose
        false,                 # debug
        false,                 # use_checksum
        nothing,               # bw_limit
        config.general.default_timeout_minutes, # timeout_minutes
        false,                 # sync_crypto
        String[],              # items_especificos
        String[],              # exclusiones_cli
        0,                     # elementos_procesados
        0,                     # errores_sincronizacion
        0,                     # archivos_transferidos
        0,                     # enlaces_creados
        0,                     # enlaces_existentes
        0,                     # enlaces_errores
        0,                     # enlaces_detectados
        0,                     # archivos_borrados
        0,                     # archivos_crypto_transferidos
        now(),                 # start_time
        joinpath(tempdir(), "syncb.lock"), # lock_file
        String[]               # temp_files
    )
end

# Cargar configuración desde TOML
function load_config(config_file::String="syncb.toml")::SyncConfig
    config_dict = TOML.parsefile(config_file)

    paths = ConfigPaths(
        expanduser(get(config_dict["paths"], "local_dir", "~")),
        expanduser(get(config_dict["paths"], "pcloud_mount_point", "~/pCloudDrive")),
        get(config_dict["paths"], "pcloud_backup_comun", "Backups/Backup_Comun"),
        get(config_dict["paths"], "pcloud_backup_readonly", "pCloud Backup/feynman.sobremesa.dnf"),
        get(config_dict["paths"], "config_search_paths", String[])
    )

    files = ConfigFiles(
        get(config_dict["files"], "symlinks_file", ".syncb_symlinks.meta"),
        expanduser(get(config_dict["files"], "log_file", "~/syncb.log"))
    )

    general = ConfigGeneral(
        get(config_dict["general"], "lock_timeout", 3600),
        get(config_dict["general"], "hostname_rtva", "feynman.rtva.dnf"),
        get(config_dict["general"], "default_timeout_minutes", 30)
    )

    colors = ConfigColors(
        get(config_dict["colors"], "red", "\033[0;31m"),
        get(config_dict["colors"], "green", "\033[0;32m"),
        get(config_dict["colors"], "yellow", "\033[1;33m"),
        get(config_dict["colors"], "blue", "\033[0;34m"),
        get(config_dict["colors"], "magenta", "\033[0;35m"),
        get(config_dict["colors"], "cyan", "\033[0;36m"),
        get(config_dict["colors"], "white", "\033[1;37m"),
        get(config_dict["colors"], "no_color", "\033[0m")
    )

    icons = ConfigIcons(
        get(config_dict["icons"], "check_mark", "✓"),
        get(config_dict["icons"], "cross_mark", "✗"),
        get(config_dict["icons"], "info_icon", "ℹ"),
        get(config_dict["icons"], "warning_icon", "⚠"),
        get(config_dict["icons"], "clock_icon", "⏱"),
        get(config_dict["icons"], "sync_icon", "🔄"),
        get(config_dict["icons"], "error_icon", "❌"),
        get(config_dict["icons"], "success_icon", "✅")
    )

    logging = ConfigLogging(
        get(config_dict["logging"], "max_size_mb", 10),
        get(config_dict["logging"], "backup_count", 5)
    )

    notifications = ConfigNotifications(
        get(config_dict["notifications"], "enabled", true)
    )

    permisos_ejecutables = ConfigPermisosEjecutables(
        get(config_dict["permisos_ejecutables"], "archivos", String[])
    )

    SyncConfig(
        paths,
        files,
        general,
        get(config_dict, "directorios_sincronizacion", String[]),
        get(config_dict, "exclusiones", String[]),
        get(config_dict, "host_specific", Dict{String,Any}()),
        permisos_ejecutables,
        logging,
        notifications,
        colors,
        icons
    )
end

# Sistema de logging mejorado
struct ColorLogger <: Logging.AbstractLogger
    min_level::Logging.LogLevel
    config::SyncConfig
    log_file::IO
end

function ColorLogger(config::SyncConfig)
    log_file = open(config.files.log_file, "a")
    ColorLogger(Logging.Info, config, log_file)
end

function Logging.handle_message(logger::ColorLogger, level, message, _module, group, id, file, line; kwargs...)
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    color = get_color(logger.config, level)
    icon = get_icon(logger.config, level)
    level_str = string(level)

    log_entry = "$timestamp - [$level_str] $message"

    # Escribir en archivo
    println(logger.log_file, log_entry)
    flush(logger.log_file)

    # Escribir en consola con colores
    console_msg = "$color$icon [$level_str]$logger.config.colors.no_color $message"
    println(console_msg)
end

Logging.min_enabled_level(logger::ColorLogger) = logger.min_level
Logging.shouldlog(logger::ColorLogger, level, _module, group, id) = true

function get_color(config::SyncConfig, level)
    if level == Logging.Error
        return config.colors.red
    elseif level == Logging.Warn
        return config.colors.yellow
    elseif level == Logging.Info
        return config.colors.blue
    elseif level == Logging.Debug
        return config.colors.magenta
    else
        return config.colors.white
    end
end

function get_icon(config::SyncConfig, level)
    if level == Logging.Error
        return config.icons.cross_mark
    elseif level == Logging.Warn
        return config.icons.warning_icon
    elseif level == Logging.Info
        return config.icons.info_icon
    elseif level == Logging.Debug
        return config.icons.clock_icon
    else
        return config.icons.info_icon
    end
end

# Funciones de logging específicas
function log_info(state::AppState, msg::String)
    @info msg
end

function log_warn(state::AppState, msg::String)
    @warn msg
end

function log_error(state::AppState, msg::String)
    @error msg
end

function log_debug(state::AppState, msg::String)
    if state.debug || state.verbose
        @debug msg
    end
end

function log_success(state::AppState, msg::String)
    success_msg = "$(state.config.icons.check_mark) [SUCCESS] $msg"
    println("$(state.config.colors.green)$success_msg$(state.config.colors.no_color)")

    # También escribir en archivo
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    log_entry = "$timestamp - [SUCCESS] $msg"
    open(state.config.files.log_file, "a") do f
        println(f, log_entry)
    end
end

# Manejo de argumentos de línea de comandos
function parse_arguments(state::AppState)
    s = ArgParseSettings(description="Sincronización bidireccional entre directorio local y pCloud")

    @add_arg_table! s begin
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
            help = "Sincroniza solo el elemento especificado"
            action = :append_arg
            nargs = 1
            arg_type = String
        "--exclude"
            help = "Excluye archivos que coincidan con el patrón"
            action = :append_arg
            nargs = 1
            arg_type = String
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
            help = "Fuerza comparación con checksum"
            action = :store_true
        "--bwlimit"
            help = "Limita la velocidad de transferencia (KB/s)"
            arg_type = String
        "--timeout"
            help = "Límite de tiempo por operación (minutos)"
            arg_type = Int
        "--force-unlock"
            help = "Forzando eliminación de lock"
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

    args = parse_args(s)

    # Procesar argumentos
    if args["subir"] && args["bajar"]
        log_error(state, "No puedes usar --subir y --bajar simultáneamente")
        exit(1)
    end

    if args["subir"]
        state.modo = "subir"
    elseif args["bajar"]
        state.modo = "bajar"
    else
        log_error(state, "Debes especificar --subir o --bajar")
        mostrar_ayuda(state)
        exit(1)
    end

    state.dry_run = args["dry-run"]
    state.delete = args["delete"]
    state.yes = args["yes"]
    state.overwrite = args["overwrite"]
    state.backup_dir_mode = args["backup-dir"] ? "readonly" : "comun"
    state.use_checksum = args["checksum"]
    state.sync_crypto = args["crypto"]
    state.verbose = args["verbose"]
    state.debug = args["debug"]

    if !isnothing(args["bwlimit"])
        state.bw_limit = args["bwlimit"]
    end

    if !isnothing(args["timeout"])
        state.timeout_minutes = args["timeout"]
    end

    if !isnothing(args["item"])
        state.items_especificos = vcat(state.items_especificos, args["item"])
    end

    if !isnothing(args["exclude"])
        state.exclusiones_cli = vcat(state.exclusiones_cli, args["exclude"])
    end

    if args["force-unlock"]
        if isfile(state.lock_file)
            rm(state.lock_file)
            log_warn(state, "Lock forzado eliminado: $(state.lock_file)")
        end
        exit(0)
    end

    return args
end

function mostrar_ayuda(state::AppState)
    println("Uso: syncb.jl [OPCIONES]")
    println()
    println("Opciones PRINCIPALES (obligatorio una de ellas):")
    println("  --subir            Sincroniza desde el directorio local a pCloud")
    println("  --bajar            Sincroniza desde pCloud al directorio local")
    println()
    println("Opciones SECUNDARIAS (opcionales):")
    println("  --delete           Elimina en destino los archivos que no existan en origen")
    println("  --dry-run          Simula la operación sin hacer cambios reales")
    println("  --item ELEMENTO    Sincroniza solo el elemento especificado")
    println("  --yes              No pregunta confirmación, ejecuta directamente")
    println("  --backup-dir       Usa el directorio de backup de solo lectura")
    println("  --exclude PATRON   Excluye archivos que coincidan con el patrón")
    println("  --overwrite        Sobrescribe todos los archivos en destino")
    println("  --checksum         Fuerza comparación con checksum")
    println("  --bwlimit KB/s     Limita la velocidad de transferencia")
    println("  --timeout MINUTOS  Límite de tiempo por operación")
    println("  --force-unlock     Forzando eliminación de lock")
    println("  --crypto           Incluye la sincronización del directorio Crypto")
    println("  --verbose          Habilita modo verboso")
    println("  --debug            Habilita modo debug")
    println("  --help             Muestra esta ayuda")
    println()
    println("Archivo de configuración: syncb.toml")
end

# Funciones de utilidad
function normalize_path(path::String)::String
    # Expandir ~
    path = expanduser(path)

    # Obtener ruta absoluta
    try
        return abspath(path)
    catch e
        return path
    end
end

function get_pcloud_dir(state::AppState)::String
    if state.backup_dir_mode == "readonly"
        return joinpath(state.config.paths.pcloud_mount_point, state.config.paths.pcloud_backup_readonly)
    else
        return joinpath(state.config.paths.pcloud_mount_point, state.config.paths.pcloud_backup_comun)
    end
end

function verificar_conectividad_pcloud(state::AppState)::Bool
    log_debug(state, "Verificando conectividad con pCloud...")

    try
        run(pipeline(`curl -s https://www.pcloud.com/`, devnull))
        log_info(state, "Verificación de conectividad pCloud: OK")
        return true
    catch e
        log_warn(state, "No se pudo verificar conectividad con pCloud: $e")
        return false
    end
end

function verificar_pcloud_montado(state::AppState)::Bool
    pcloud_dir = get_pcloud_dir(state)
    mount_point = state.config.paths.pcloud_mount_point

    log_debug(state, "Verificando montaje de pCloud en: $mount_point")

    if !isdir(mount_point)
        log_error(state, "El punto de montaje de pCloud no existe: $mount_point")
        return false
    end

    # Verificar si el directorio está vacío
    if isempty(readdir(mount_point))
        log_error(state, "El directorio de pCloud está vacío: $mount_point")
        return false
    end

    # Verificar si el directorio específico existe
    if !isdir(pcloud_dir)
        log_error(state, "El directorio de pCloud no existe: $pcloud_dir")
        return false
    end

    # Verificar permisos de escritura (solo si no es dry-run y no es modo backup-dir)
    if !state.dry_run && state.backup_dir_mode == "comun"
        test_file = joinpath(pcloud_dir, ".test_write_$(getpid())")
        try
            touch(test_file)
            rm(test_file)
        catch e
            log_error(state, "No se puede escribir en: $pcloud_dir")
            return false
        end
    end

    log_info(state, "Verificación de pCloud: OK - El directorio está montado y accesible")
    return true
end

function establecer_lock(state::AppState)::Bool
    if isfile(state.lock_file)
        try
            lock_content = read(state.lock_file, String)
            lock_pid = parse(Int, split(lock_content, "\n")[1])

            if isprocessalive(lock_pid)
                log_error(state, "Ya hay una ejecución en progreso (PID: $lock_pid)")
                return false
            else
                log_warn(state, "Eliminando lock obsoleto del proceso $lock_pid")
                rm(state.lock_file)
            end
        catch e
            log_warn(state, "Lock corrupto, eliminando: $e")
            rm(state.lock_file)
        end
    end

    try
        open(state.lock_file, "w") do f
            println(f, getpid())
            println(f, "Fecha: $(now())")
            println(f, "Modo: $(state.modo)")
            println(f, "Usuario: $(ENV["USER"])")
            println(f, "Hostname: $(gethostname())")
        end
        log_info(state, "Lock establecido: $(state.lock_file)")
        return true
    catch e
        log_error(state, "No se pudo crear el archivo de lock: $(state.lock_file)")
        return false
    end
end

function eliminar_lock(state::AppState)
    if isfile(state.lock_file)
        try
            lock_content = read(state.lock_file, String)
            if occursin(string(getpid()), split(lock_content, "\n")[1])
                rm(state.lock_file)
                log_info(state, "Lock eliminado")
            end
        catch e
            log_warn(state, "Error al eliminar lock: $e")
        end
    end
end

function mostrar_banner(state::AppState)
    pcloud_dir = get_pcloud_dir(state)

    println("="^50)
    if state.modo == "subir"
        println("MODO: SUBIR (Local → pCloud)")
        println("ORIGEN: $(state.config.paths.local_dir)")
        println("DESTINO: $pcloud_dir")
    else
        println("MODO: BAJAR (pCloud → Local)")
        println("ORIGEN: $pcloud_dir")
        println("DESTINO: $(state.config.paths.local_dir)")
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
        println("BORRADO: ACTIVADO (se eliminarán archivos obsoletos)")
    end

    if state.yes
        println("CONFIRMACIÓN: Automática (sin preguntar)")
    end

    if state.overwrite
        println("SOBRESCRITURA: ACTIVADA")
    else
        println("MODO: SEGURO (--update activado)")
    end

    if state.sync_crypto
        println("CRYPTO: INCLUIDO")
    else
        println("CRYPTO: EXCLUIDO")
    end

    if !isempty(state.items_especificos)
        println("ELEMENTOS ESPECÍFICOS: $(join(state.items_especificos, ", "))")
    else
        println("LISTA: $(length(state.config.directorios_sincronizacion)) elementos")
    end

    println("EXCLUSIONES: $(length(state.config.exclusiones)) patrones")

    if !isempty(state.exclusiones_cli)
        println("EXCLUSIONES CLI: $(length(state.exclusiones_cli)) patrones")
    end
    println("="^50)
end

function confirmar_ejecucion(state::AppState)
    if state.yes
        log_info(state, "Confirmación automática (--yes): se procede con la sincronización")
        return
    end

    println()
    print("¿Desea continuar con la sincronización? [s/N]: ")
    respuesta = readline()

    if !startswith(lowercase(respuesta), "s")
        log_info(state, "Operación cancelada por el usuario.")
        exit(0)
    end
    println()
end

function verificar_dependencias(state::AppState)
    log_debug(state, "Verificando dependencias...")

    # Verificar rsync
    try
        run(`rsync --version`)
    catch e
        log_error(state, "rsync no está instalado. Instálalo con:")
        log_info(state, "sudo apt install rsync  # Debian/Ubuntu")
        log_info(state, "sudo dnf install rsync  # RedHat/CentOS")
        exit(1)
    end

    # Verificar curl para conectividad
    try
        run(`curl --version`)
    catch e
        log_warn(state, "curl no disponible, algunas verificaciones se omitirán")
    end
end

# Funciones de sincronización
function construir_opciones_rsync(state::AppState)::Vector{String}
    opts = ["--recursive", "--verbose", "--times", "--progress", "--itemize-changes"]

    if !state.overwrite
        push!(opts, "--update")
    end

    if state.dry_run
        push!(opts, "--dry-run")
    end

    if state.delete
        push!(opts, "--delete-delay")
    end

    if state.use_checksum
        push!(opts, "--checksum")
    end

    if !isnothing(state.bw_limit)
        push!(opts, "--bwlimit=$(state.bw_limit)")
    end

    # Añadir exclusiones del archivo de configuración
    for exclusion in state.config.exclusiones
        push!(opts, "--exclude=$exclusion")
    end

    # Añadir exclusiones de línea de comandos
    for exclusion in state.exclusiones_cli
        push!(opts, "--exclude=$exclusion")
    end

    return opts
end

function sincronizar_elemento(state::AppState, elemento::String)::Bool
    pcloud_dir = get_pcloud_dir(state)

    if state.modo == "subir"
        origen = joinpath(state.config.paths.local_dir, elemento)
        destino = joinpath(pcloud_dir, elemento)
        direccion = "LOCAL → PCLOUD (Subir)"
    else
        origen = joinpath(pcloud_dir, elemento)
        destino = joinpath(state.config.paths.local_dir, elemento)
        direccion = "PCLOUD → LOCAL (Bajar)"
    end

    if !exists(origen)
        log_warn(state, "No existe $origen")
        return false
    end

    # Crear directorio destino si no existe
    dir_destino = dirname(destino)
    if !isdir(dir_destino) && !state.dry_run
        mkpath(dir_destino)
        log_info(state, "Directorio creado: $dir_destino")
    end

    log_info(state, "Sincronizando: $elemento ($direccion)")

    rsync_opts = construir_opciones_rsync(state)

    try
        if state.dry_run
            log_info(state, "SIMULACIÓN: rsync $(join(rsync_opts, " ")) \"$origen\" \"$destino\"")
            # Simular conteo de archivos
            if isdir(origen)
                file_count = count(x -> isfile(x), walkdir(origen))
                state.archivos_transferidos += file_count
            else
                state.archivos_transferidos += 1
            end
        else
            run(`rsync $rsync_opts $origen $destino`)

            # Contar archivos transferidos (simplificado)
            if isdir(origen)
                file_count = count(x -> isfile(x), walkdir(origen))
                state.archivos_transferidos += file_count
            else
                state.archivos_transferidos += 1
            end
        end

        state.elementos_procesados += 1
        log_success(state, "Sincronización completada: $elemento")
        return true

    catch e
        log_error(state, "Error en sincronización: $elemento - $e")
        state.errores_sincronizacion += 1
        return false
    end
end

function procesar_elementos(state::AppState)::Bool
    exit_code = true

    elementos_a_procesar = isempty(state.items_especificos) ?
                          state.config.directorios_sincronizacion :
                          state.items_especificos

    log_info(state, "Procesando $(length(elementos_a_procesar)) elementos")

    for elemento in elementos_a_procesar
        if !sincronizar_elemento(state, elemento)
            exit_code = false
        end
        println("-"^50)
    end

    return exit_code
end

# Funciones para enlaces simbólicos
function generar_archivo_enlaces(state::AppState)::Bool
    temp_file = tempname()
    push!(state.temp_files, temp_file)

    log_info(state, "Generando archivo de enlaces simbólicos...")

    open(temp_file, "w") do f
        elementos_a_procesar = isempty(state.items_especificos) ?
                              state.config.directorios_sincronizacion :
                              state.items_especificos

        for elemento in elementos_a_procesar
            ruta_completa = joinpath(state.config.paths.local_dir, elemento)

            if islink(ruta_completa)
                registrar_enlace(state, ruta_completa, f)
            elseif isdir(ruta_completa)
                buscar_enlaces_en_directorio(state, ruta_completa, f)
            end
        end
    end

    if filesize(temp_file) > 0
        pcloud_dir = get_pcloud_dir(state)
        destino = joinpath(pcloud_dir, state.config.files.symlinks_file)

        try
            if !state.dry_run
                cp(temp_file, destino; force=true)
            end
            log_info(state, "Enlaces detectados/guardados: $(state.enlaces_detectados)")
            log_info(state, "Archivo de enlaces sincronizado")
        catch e
            log_error(state, "Error sincronizando archivo de enlaces: $e")
            return false
        end
    else
        log_info(state, "No se encontraron enlaces simbólicos para registrar")
    end

    return true
end

function registrar_enlace(state::AppState, enlace::String, archivo::IO)
    ruta_relativa = relpath(enlace, state.config.paths.local_dir)
    destino = readlink(enlace)

    if isempty(ruta_relativa) || isempty(destino)
        log_warn(state, "Enlace no válido o origen/destino vacío: $enlace")
        return
    end

    # Normalizar destino
    if startswith(destino, state.config.paths.local_dir)
        destino = replace(destino, state.config.paths.local_dir => "/home/\$USERNAME")
    end

    println(archivo, "$ruta_relativa\t$destino")
    state.enlaces_detectados += 1
    log_debug(state, "Registrado enlace simbólico: $ruta_relativa -> $destino")
end

function buscar_enlaces_en_directorio(state::AppState, directorio::String, archivo::IO)
    for (root, dirs, files) in walkdir(directorio)
        for file in files
            ruta_completa = joinpath(root, file)
            if islink(ruta_completa)
                registrar_enlace(state, ruta_completa, archivo)
            end
        end
    end
end

function recrear_enlaces_desde_archivo(state::AppState)::Bool
    pcloud_dir = get_pcloud_dir(state)
    archivo_enlaces_origen = joinpath(pcloud_dir, state.config.files.symlinks_file)
    archivo_enlaces_local = joinpath(state.config.paths.local_dir, state.config.files.symlinks_file)

    if !isfile(archivo_enlaces_origen) && !isfile(archivo_enlaces_local)
        log_info(state, "No se encontró archivo de enlaces, omitiendo recreación")
        return true
    end

    archivo_a_usar = isfile(archivo_enlaces_origen) ? archivo_enlaces_origen : archivo_enlaces_local

    log_info(state, "Recreando enlaces simbólicos desde: $archivo_a_usar")

    exit_code = true
    open(archivo_a_usar) do f
        for linea in eachline(f)
            partes = split(linea, '\t')
            if length(partes) == 2
                ruta_enlace, destino = partes
                if !procesar_linea_enlace(state, ruta_enlace, destino)
                    exit_code = false
                end
            else
                log_warn(state, "Línea inválida en archivo de enlaces: $linea")
            end
        end
    end

    log_info(state, "Enlaces recreados: $(state.enlaces_creados), Errores: $(state.enlaces_errores)")

    if !state.dry_run && isfile(archivo_enlaces_local)
        rm(archivo_enlaces_local)
    end

    return exit_code
end

function procesar_linea_enlace(state::AppState, ruta_enlace::String, destino::String)::Bool
    ruta_completa = joinpath(state.config.paths.local_dir, ruta_enlace)
    dir_padre = dirname(ruta_completa)

    # Normalizar destino
    destino_normalizado = replace(destino, "\$USERNAME" => ENV["USER"])
    destino_normalizado = replace(destino_normalizado, "\$HOME" => ENV["HOME"])

    if !isdir(dir_padre) && !state.dry_run
        mkpath(dir_padre)
    end

    if islink(ruta_completa)
        destino_actual = readlink(ruta_completa)
        if destino_actual == destino_normalizado
            state.enlaces_existentes += 1
            return true
        else
            if !state.dry_run
                rm(ruta_completa)
            end
        end
    end

    if state.dry_run
        log_debug(state, "SIMULACIÓN: Enlace a crear: $ruta_completa -> $destino_normalizado")
        state.enlaces_creados += 1
    else
        try
            symlink(destino_normalizado, ruta_completa)
            log_debug(state, "Enlace creado: $ruta_completa -> $destino_normalizado")
            state.enlaces_creados += 1
        catch e
            log_error(state, "Error creando enlace: $ruta_enlace -> $destino_normalizado - $e")
            state.enlaces_errores += 1
            return false
        end
    end

    return true
end

# Función principal de sincronización
function sincronizar(state::AppState)::Bool
    log_info(state, "Iniciando proceso de sincronización en modo: $(state.modo)")

    # Verificaciones previas
    if !verificar_pcloud_montado(state)
        log_error(state, "Fallo en verificación de pCloud montado - abortando")
        return false
    end

    verificar_conectividad_pcloud(state)

    # Confirmación de ejecución
    if !state.dry_run
        confirmar_ejecucion(state)
    end

    # Procesar elementos
    exit_code = procesar_elementos(state)

    # Manejar enlaces simbólicos
    if state.modo == "subir"
        if !generar_archivo_enlaces(state)
            exit_code = false
        end
    else
        if !recrear_enlaces_desde_archivo(state)
            exit_code = false
        end
    end

    return exit_code
end

# Función para mostrar estadísticas
function mostrar_estadisticas(state::AppState)
    tiempo_total = round(Int, (now() - state.start_time).value / 1000)  # segundos

    horas = tiempo_total ÷ 3600
    minutos = (tiempo_total % 3600) ÷ 60
    segundos = tiempo_total % 60

    println()
    println("="^50)
    println("RESUMEN DE SINCRONIZACIÓN")
    println("="^50)
    println("Elementos procesados: $(state.elementos_procesados)")
    println("Archivos transferidos: $(state.archivos_transferidos)")

    if state.delete
        println("Archivos borrados en destino: $(state.archivos_borrados)")
    end

    if !isempty(state.exclusiones_cli)
        println("Exclusiones CLI aplicadas: $(length(state.exclusiones_cli)) patrones")
    end

    println("Enlaces manejados: $(state.enlaces_creados + state.enlaces_existentes)")
    println("  - Enlaces detectados/guardados: $(state.enlaces_detectados)")
    println("  - Enlaces creados: $(state.enlaces_creados)")
    println("  - Enlaces existentes: $(state.enlaces_existentes)")
    println("  - Enlaces con errores: $(state.enlaces_errores)")
    println("Errores de sincronización: $(state.errores_sincronizacion)")

    if tiempo_total >= 3600
        println("Tiempo total: $(horas)h $(minutos)m $(segundos)s")
    elseif tiempo_total >= 60
        println("Tiempo total: $(minutos)m $(segundos)s")
    else
        println("Tiempo total: $(segundos)s")
    end

    velocidad = state.archivos_transferidos / max(tiempo_total, 1)
    println("Velocidad promedio: $(round(velocidad, digits=2)) archivos/segundo")
    println("Modo: $(state.dry_run ? "SIMULACIÓN" : "EJECUCIÓN REAL")")
    println("="^50)
end

# Función para limpieza
function cleanup(state::AppState)
    # Eliminar archivos temporales
    for temp_file in state.temp_files
        if isfile(temp_file)
            try
                rm(temp_file)
            catch e
                log_warn(state, "No se pudo eliminar archivo temporal: $temp_file")
            end
        end
    end

    # Eliminar lock
    eliminar_lock(state)
end

# Función principal
function main()
    # Instalar paquetes requeridos
    install_required_packages()

    # Cargar configuración
    config = load_config("syncb.toml")

    # Crear estado de la aplicación
    state = AppState(config)

    # Configurar logger
    logger = ColorLogger(config)
    global_logger(logger)

    # Parsear argumentos
    parse_arguments(state)

    # Mostrar banner
    mostrar_banner(state)

    # Establecer locking
    if !establecer_lock(state)
        exit(1)
    end

    # Registrar limpieza al salir
    atexit(() -> cleanup(state))

    # Verificar dependencias
    verificar_dependencias(state)

    # Inicializar log
    log_info(state, "Sincronización iniciada: $(now())")
    log_info(state, "Modo: $(state.modo)")
    log_info(state, "Delete: $(state.delete)")
    log_info(state, "Dry-run: $(state.dry_run)")
    log_info(state, "Backup-dir: $(state.backup_dir_mode)")

    # Ejecutar sincronización
    exit_code = sincronizar(state)

    # Mostrar estadísticas
    mostrar_estadisticas(state)

    # Escribir resumen en log
    open(config.files.log_file, "a") do f
        println(f, "="^50)
        println(f, "Sincronización finalizada: $(now())")
        println(f, "Elementos procesados: $(state.elementos_procesados)")
        println(f, "Archivos transferidos: $(state.archivos_transferidos)")
        println(f, "Modo dry-run: $(state.dry_run)")
        println(f, "Enlaces detectados/guardados: $(state.enlaces_detectados)")
        println(f, "Enlaces creados: $(state.enlaces_creados)")
        println(f, "Enlaces existentes: $(state.enlaces_existentes)")
        println(f, "Enlaces con errores: $(state.enlaces_errores)")
        println(f, "Errores generales: $(state.errores_sincronizacion)")
        println(f, "Log: $(config.files.log_file)")
        println(f, "="^50)
    end

    exit(exit_code ? 0 : 1)
end

# Ejecutar aplicación
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
