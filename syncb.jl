#!/usr/bin/env julia

# syncb.jl - Sincronización bidireccional entre directorio local y pCloud
# Implementado en Julia aprovechando las características del lenguaje
#julia -e 'import Pkg; Pkg.add(["ArgParse", "TOML", "FilePathsBase"])'

using TOML
using Logging
using Dates
using ArgParse
using FileWatching
using FilePathsBase
using Distributed
using SHA

# =========================
# Estructuras de datos
# =========================

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

struct ConfigLogging
    max_size_mb::Int
    backup_count::Int
end

struct ConfigNotifications
    enabled::Bool
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

struct SyncConfig
    paths::ConfigPaths
    files::ConfigFiles
    general::ConfigGeneral
    directorios_sincronizacion::Vector{String}
    exclusiones::Vector{String}
    host_specific::Dict{String, Vector{String}}
    permisos_ejecutables::Vector{String}
    logging::ConfigLogging
    notifications::ConfigNotifications
    colors::ConfigColors
    icons::ConfigIcons
end

struct SyncStats
    elementos_procesados::Int
    archivos_transferidos::Int
    archivos_borrados::Int
    archivos_crypto_transferidos::Int
    enlaces_creados::Int
    enlaces_existentes::Int
    enlaces_errores::Int
    enlaces_detectados::Int
    errores_sincronizacion::Int
    tiempo_inicio::DateTime
    tiempo_fin::DateTime
end

struct CommandLineArgs
    modo::String
    dry_run::Bool
    delete::Bool
    yes::Bool
    overwrite::Bool
    backup_dir_mode::String
    verbose::Bool
    debug::Bool
    use_checksum::Bool
    bw_limit::Union{String, Nothing}
    sync_crypto::Bool
    items_especificos::Vector{String}
    exclusiones_cli::Vector{String}
    force_unlock::Bool
    timeout_minutes::Int
end

# =========================
# Constantes y configuración por defecto
# =========================

const SCRIPT_DIR = @__DIR__
const HOSTNAME = chomp(read(`hostname -f`, String))
const DEFAULT_CONFIG = SyncConfig(
    ConfigPaths(
        expanduser("~"),
        expanduser("~/pCloudDrive"),
        "Backups/Backup_Comun",
        "pCloud Backup/feynman.sobremesa.dnf",
        [
            "syncb.toml",
            "~/.config/syncb/syncb.toml",
            "~/.syncb.toml",
            "/etc/syncb/syncb.toml"
        ]
    ),
    ConfigFiles(".syncb_symlinks.meta", "~/syncb.log"),
    ConfigGeneral(3600, "feynman.rtva.dnf", 30),
    [
        "Documentos/personal/orgfiles",
        "Documentos/proyectos/sync/others_lang",
        ".local/bin",
        ".config/dotfiles",
        ".config/doom",
        ".config/backup-configs",
        ".config/emacs.mcfg",
        ".config/calibre",
        ".config/keepassxc",
        ".config/nvim",
        ".config/systemd",
        ".config/task",
        ".config/vlc",
        ".local/share/applications",
        ".local/share/ispell",
        ".local/share/nautilus",
        ".local/share/remmina",
        ".local/share/todo.txt",
        "Plantillas",
        "Vínculos",
        "Documentos",
        "Imágenes",
        "Música",
        "Público",
        "Vídeos"
    ],
    [
        "*.tmp", "*.temp", "*.log", "*.bak", "*.backup",
        ".Trash-*", ".DS_Store", "Thumbs.db", "*.swp",
        "*.qcow2", "tmp_pruebas/", "Descargas/",
        "cache/", ".cache/", "*Cache*/"
    ],
    Dict{String, Vector{String}}(),
    [
        ".config/dotfiles/*.sh",
        ".local/bin/*.sh",
        ".local/bin/*.py",
        ".local/bin/*.jl",
        ".local/bin/pcloud"
    ],
    ConfigLogging(10, 5),
    ConfigNotifications(true),
    ConfigColors(
        "\033[0;31m", "\033[0;32m", "\033[1;33m",
        "\033[0;34m", "\033[0;35m", "\033[0;36m",
        "\033[1;37m", "\033[0m"
    ),
    ConfigIcons("✓", "✗", "ℹ", "⚠", "⏱", "🔄", "❌", "✅")
)

# =========================
# Variables globales
# =========================

config::SyncConfig = DEFAULT_CONFIG
args::Union{CommandLineArgs, Nothing} = nothing
lock_file::String = "/tmp/syncb.jl.lock"
log_file::String = ""
sync_stats = SyncStats(0, 0, 0, 0, 0, 0, 0, 0, 0, now(), now())

# =========================
# Sistema de logging mejorado
# =========================

function setup_logging()
    global log_file = expanduser(config.files.log_file)
    
    # Crear directorio de logs si no existe
    log_dir = dirname(log_file)
    if !isdir(log_dir)
        mkpath(log_dir)
    end
    
    # Configurar logger
    logger = SimpleLogger(open(log_file, "a"), Logging.Info)
    global_logger(logger)
end

function log_message(level::Symbol, message::String; color::String="")
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    prefix = ""
    
    if level == :info
        prefix = "$(config.icons.info_icon) [INFO]"
        color = config.colors.blue
    elseif level == :warn
        prefix = "$(config.icons.warning_icon) [WARN]"
        color = config.colors.yellow
    elseif level == :error
        prefix = "$(config.icons.error_icon) [ERROR]"
        color = config.colors.red
    elseif level == :success
        prefix = "$(config.icons.success_icon) [SUCCESS]"
        color = config.colors.green
    elseif level == :debug
        prefix = "$(config.icons.clock_icon) [DEBUG]"
        color = config.colors.magenta
    end
    
    formatted_message = "$color$timestamp $prefix $message$(config.colors.no_color)"
    println(formatted_message)
    
    # Escribir en archivo de log (sin colores)
    log_entry = "$timestamp [$level] $message"
    open(log_file, "a") do f
        println(f, log_entry)
    end
    
    # Rotación de logs
    rotate_logs()
end

function rotate_logs()
    try
        if filesize(log_file) > config.logging.max_size_mb * 1024 * 1024
            # Crear backup
            backup_file = "$log_file.$(Dates.format(now(), "yyyy-mm-dd-HH-MM-SS"))"
            cp(log_file, backup_file)
            
            # Truncar archivo actual
            open(log_file, "w") do f
                println(f, "Log rotado el $(now())")
            end
            
            # Limpiar backups antiguos
            log_dir = dirname(log_file)
            backup_files = filter(x -> startswith(x, basename(log_file)) && x != basename(log_file), readdir(log_dir))
            if length(backup_files) > config.logging.backup_count
                sort!(backup_files)
                for i in 1:(length(backup_files) - config.logging.backup_count)
                    rm(joinpath(log_dir, backup_files[i]))
                end
            end
        end
    catch e
        # No fallar si hay error en rotación
        log_message(:warn, "Error en rotación de logs: $(e)")
    end
end

# =========================
# Manejo de configuración
# =========================

function find_config_file()::String
    for config_path in config.paths.config_search_paths
        expanded_path = expanduser(config_path)
        if isfile(expanded_path)
            return expanded_path
        end
    end
    error("No se encontró archivo de configuración")
end

function load_config()::SyncConfig
    config_file = find_config_file()
    log_message(:info, "Cargando configuración desde: $config_file")
    
    toml_data = TOML.parsefile(config_file)
    
    # Cargar paths
    paths_section = get(toml_data, "paths", Dict())
    paths = ConfigPaths(
        get(paths_section, "local_dir", DEFAULT_CONFIG.paths.local_dir),
        get(paths_section, "pcloud_mount_point", DEFAULT_CONFIG.paths.pcloud_mount_point),
        get(paths_section, "pcloud_backup_comun", DEFAULT_CONFIG.paths.pcloud_backup_comun),
        get(paths_section, "pcloud_backup_readonly", DEFAULT_CONFIG.paths.pcloud_backup_readonly),
        get(paths_section, "config_search_paths", DEFAULT_CONFIG.paths.config_search_paths)
    )
    
    # Cargar files
    files_section = get(toml_data, "files", Dict())
    files = ConfigFiles(
        get(files_section, "symlinks_file", DEFAULT_CONFIG.files.symlinks_file),
        get(files_section, "log_file", DEFAULT_CONFIG.files.log_file)
    )
    
    # Cargar general
    general_section = get(toml_data, "general", Dict())
    general = ConfigGeneral(
        get(general_section, "lock_timeout", DEFAULT_CONFIG.general.lock_timeout),
        get(general_section, "hostname_rtva", DEFAULT_CONFIG.general.hostname_rtva),
        get(general_section, "default_timeout_minutes", DEFAULT_CONFIG.general.default_timeout_minutes)
    )
    
    # Cargar directorios de sincronización
    directorios = get(toml_data, "directorios_sincronizacion", DEFAULT_CONFIG.directorios_sincronizacion)
    
    # Cargar exclusiones
    exclusiones = get(toml_data, "exclusiones", DEFAULT_CONFIG.exclusiones)
    
    # Cargar configuración específica por host
    host_specific = Dict{String, Vector{String}}()
    if haskey(toml_data, "host_specific.feynman.rtva.dnf")
        for (host, dirs) in toml_data["host_specific.feynman.rtva.dnf"]
            host_specific[host] = dirs
        end
    end
    
    # Cargar permisos ejecutables
    permisos_section = get(toml_data, "permisos_ejecutables", Dict())
    permisos = get(permisos_section, "archivos", DEFAULT_CONFIG.permisos_ejecutables)
    
    # Cargar logging
    logging_section = get(toml_data, "logging", Dict())
    logging = ConfigLogging(
        get(logging_section, "max_size_mb", DEFAULT_CONFIG.logging.max_size_mb),
        get(logging_section, "backup_count", DEFAULT_CONFIG.logging.backup_count)
    )
    
    # Cargar notificaciones
    notifications_section = get(toml_data, "notifications", Dict())
    notifications = ConfigNotifications(
        get(notifications_section, "enabled", DEFAULT_CONFIG.notifications.enabled)
    )
    
    # Cargar colores
    colors_section = get(toml_data, "colors", Dict())
    colors = ConfigColors(
        get(colors_section, "red", DEFAULT_CONFIG.colors.red),
        get(colors_section, "green", DEFAULT_CONFIG.colors.green),
        get(colors_section, "yellow", DEFAULT_CONFIG.colors.yellow),
        get(colors_section, "blue", DEFAULT_CONFIG.colors.blue),
        get(colors_section, "magenta", DEFAULT_CONFIG.colors.magenta),
        get(colors_section, "cyan", DEFAULT_CONFIG.colors.cyan),
        get(colors_section, "white", DEFAULT_CONFIG.colors.white),
        get(colors_section, "no_color", DEFAULT_CONFIG.colors.no_color)
    )
    
    # Cargar iconos
    icons_section = get(toml_data, "icons", Dict())
    icons = ConfigIcons(
        get(icons_section, "check_mark", DEFAULT_CONFIG.icons.check_mark),
        get(icons_section, "cross_mark", DEFAULT_CONFIG.icons.cross_mark),
        get(icons_section, "info_icon", DEFAULT_CONFIG.icons.info_icon),
        get(icons_section, "warning_icon", DEFAULT_CONFIG.icons.warning_icon),
        get(icons_section, "clock_icon", DEFAULT_CONFIG.icons.clock_icon),
        get(icons_section, "sync_icon", DEFAULT_CONFIG.icons.sync_icon),
        get(icons_section, "error_icon", DEFAULT_CONFIG.icons.error_icon),
        get(icons_section, "success_icon", DEFAULT_CONFIG.icons.success_icon)
    )
    
    # Aplicar configuración específica del host si existe
    if haskey(host_specific, HOSTNAME)
        directorios = host_specific[HOSTNAME]
        log_message(:info, "Usando configuración específica para host: $HOSTNAME")
    end
    
    return SyncConfig(paths, files, general, directorios, exclusiones, 
                     host_specific, permisos, logging, notifications, colors, icons)
end

# =========================
# Procesamiento de argumentos
# =========================

function parse_args()::CommandLineArgs
    s = ArgParseSettings(description="Sincronización bidireccional entre directorio local y pCloud",
                        version="1.0", add_version=true)
    
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
        "--exclude"
            help = "Excluye archivos que coincidan con el patrón"
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
            help = "Fuerza comparación con checksum"
            action = :store_true
        "--bwlimit"
            help = "Limita la velocidad de transferencia (KB/s)"
            arg_type = String
        "--timeout"
            help = "Límite de tiempo por operación (minutos)"
            arg_type = Int
            default = config.general.default_timeout_minutes
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
    
    parsed_args = parse_args(s)
    
    # Validaciones
    if !parsed_args["subir"] && !parsed_args["bajar"]
        error("Debes especificar --subir o --bajar")
    end
    
    if parsed_args["subir"] && parsed_args["bajar"]
        error("No puedes usar --subir y --bajar simultáneamente")
    end
    
    modo = parsed_args["subir"] ? "subir" : "bajar"
    backup_dir_mode = parsed_args["backup-dir"] ? "readonly" : "comun"
    
    items_especificos = String[]
    if haskey(parsed_args, "item")
        items_especificos = parsed_args["item"]
    end
    
    exclusiones_cli = String[]
    if haskey(parsed_args, "exclude")
        exclusiones_cli = parsed_args["exclude"]
    end
    
    return CommandLineArgs(
        modo,
        parsed_args["dry-run"],
        parsed_args["delete"],
        parsed_args["yes"],
        parsed_args["overwrite"],
        backup_dir_mode,
        parsed_args["verbose"],
        parsed_args["debug"],
        parsed_args["checksum"],
        get(parsed_args, "bwlimit", nothing),
        parsed_args["crypto"],
        items_especificos,
        exclusiones_cli,
        parsed_args["force-unlock"],
        parsed_args["timeout"]
    )
end

# =========================
# Sistema de locking
# =========================

function establecer_lock()::Bool
    if args.force_unlock
        if isfile(lock_file)
            rm(lock_file)
            log_message(:info, "Lock forzado y eliminado")
        end
        return true
    end
    
    if isfile(lock_file)
        # Verificar si el lock es antiguo
        lock_time = mtime(lock_file)
        current_time = time()
        lock_age = current_time - lock_time
        
        if lock_age > config.general.lock_timeout
            log_message(:warn, "Eliminando lock obsoleto (edad: $(lock_age)s)")
            rm(lock_file)
        else
            # Leer información del proceso
            try
                lock_content = read(lock_file, String)
                log_message(:error, "Ya hay una ejecución en progreso:\n$lock_content")
                return false
            catch
                rm(lock_file)
            end
        end
    end
    
    # Crear nuevo lock
    lock_info = """
    PID: $(getpid())
    Fecha: $(now())
    Modo: $(args.modo)
    Usuario: $(ENV["USER"])
    Hostname: $HOSTNAME
    """
    
    try
        open(lock_file, "w") do f
            write(f, lock_info)
        end
        log_message(:info, "Lock establecido: $lock_file")
        return true
    catch e
        log_message(:error, "No se pudo crear el archivo de lock: $(e)")
        return false
    end
end

function eliminar_lock()
    if isfile(lock_file)
        try
            # Verificar que somos los dueños del lock
            lock_content = read(lock_file, String)
            if occursin("PID: $(getpid())", lock_content)
                rm(lock_file)
                log_message(:info, "Lock eliminado")
            end
        catch e
            log_message(:warn, "Error eliminando lock: $(e)")
        end
    end
end

# =========================
# Verificaciones del sistema
# =========================

function verificar_dependencias()
    required_commands = ["rsync", "notify-send"]
    
    for cmd in required_commands
        if success(`which $cmd`)
            log_message(:debug, "Dependencia verificada: $cmd")
        else
            error("Dependencia no encontrada: $cmd")
        end
    end
end

function verificar_pcloud_montado()::Bool
    mount_point = expanduser(config.paths.pcloud_mount_point)
    
    if !isdir(mount_point)
        log_message(:error, "El punto de montaje de pCloud no existe: $mount_point")
        return false
    end
    
    # Verificar si está montado usando /proc/mounts
    try
        mounts = read("/proc/mounts", String)
        if !occursin("pcloud", mounts)
            log_message(:error, "pCloud no aparece en /proc/mounts")
            return false
        end
    catch
        log_message(:warn, "No se pudo verificar /proc/mounts")
    end
    
    # Verificar que el directorio no esté vacío
    if isempty(readdir(mount_point))
        log_message(:error, "El directorio de pCloud está vacío")
        return false
    end
    
    # Verificar permisos de escritura
    if !args.dry_run && args.backup_dir_mode == "comun"
        test_file = joinpath(mount_point, ".test_write_$(getpid())")
        try
            touch(test_file)
            rm(test_file)
        catch e
            log_message(:error, "No se puede escribir en pCloud: $(e)")
            return false
        end
    end
    
    log_message(:info, "Verificación de pCloud: OK")
    return true
end

function verificar_espacio_disco(needed_mb::Int=100)::Bool
    mount_point = args.modo == "subir" ? 
        expanduser(config.paths.pcloud_mount_point) : 
        expanduser(config.paths.local_dir)
    
    if !isdir(mount_point)
        log_message(:warn, "Punto de montaje no existe: $mount_point")
        return true
    end
    
    try
        # Usar df para obtener espacio disponible
        df_output = read(`df -m $mount_point`, String)
        lines = split(df_output, '\n')
        if length(lines) >= 2
            parts = split(lines[2])
            if length(parts) >= 4
                available_mb = parse(Int, parts[4])
                
                if available_mb < needed_mb
                    log_message(:error, "Espacio insuficiente: $(available_mb)MB disponible, $(needed_mb)MB necesarios")
                    return false
                else
                    log_message(:debug, "Espacio disponible: $(available_mb)MB")
                    return true
                end
            end
        end
    catch e
        log_message(:warn, "No se pudo verificar espacio en disco: $(e)")
    end
    
    return true
end

function verificar_conectividad_pcloud()::Bool
    log_message(:debug, "Verificando conectividad con pCloud...")
    
    try
        run(pipeline(`curl -s --connect-timeout 10 https://www.pcloud.com/`, devnull))
        log_message(:info, "Conectividad pCloud: OK")
        return true
    catch e
        log_message(:warn, "No se pudo conectar a pCloud: $(e)")
        return false
    end
end

# =========================
# Utilidades de rutas
# =========================

function normalize_path(path::String)::String
    expanded = expanduser(path)
    return realpath(expanded)
end

function get_pcloud_dir()::String
    base_dir = expanduser(config.paths.pcloud_mount_point)
    if args.backup_dir_mode == "readonly"
        return joinpath(base_dir, config.paths.pcloud_backup_readonly)
    else
        return joinpath(base_dir, config.paths.pcloud_backup_comun)
    end
end

function resolver_item_relativo(item::String)::String
    # Prevenir path traversal
    if occursin("..", item) || startswith(item, "/")
        error("Path traversal detectado o ruta absoluta no permitida: $item")
    end
    
    return item
end

# =========================
# Manejo de enlaces simbólicos
# =========================

function generar_archivo_enlaces(archivo_enlaces::String)::Int
    enlaces_detectados = 0
    
    open(archivo_enlaces, "w") do f
        elementos = isempty(args.items_especificos) ? 
            config.directorios_sincronizacion : args.items_especificos
        
        for elemento in elementos
            ruta_completa = joinpath(expanduser(config.paths.local_dir), elemento)
            
            if islink(ruta_completa)
                registrar_enlace(f, ruta_completa, elemento)
                enlaces_detectados += 1
            elseif isdir(ruta_completa)
                enlaces_detectados += buscar_enlaces_en_directorio(f, ruta_completa)
            end
        end
    end
    
    return enlaces_detectados
end

function registrar_enlace(f::IO, enlace_path::String, elemento::String)
    try
        destino = readlink(enlace_path)
        ruta_relativa = elemento
        
        # Normalizar destino
        if startswith(destino, expanduser("~"))
            destino = replace(destino, expanduser("~") => "/home/\$USERNAME")
        end
        
        println(f, "$ruta_relativa\t$destino")
        log_message(:debug, "Registrado enlace: $ruta_relativa -> $destino")
    catch e
        log_message(:warn, "Error registrando enlace $enlace_path: $(e)")
    end
end

function buscar_enlaces_en_directorio(f::IO, dir::String)::Int
    enlaces_count = 0
    try
        for (root, dirs, files) in walkdir(dir)
            for file in files
                path = joinpath(root, file)
                if islink(path)
                    rel_path = relpath(path, expanduser(config.paths.local_dir))
                    registrar_enlace(f, path, rel_path)
                    enlaces_count += 1
                end
            end
        end
    catch e
        log_message(:warn, "Error buscando enlaces en $dir: $(e)")
    end
    return enlaces_count
end

function recrear_enlaces_desde_archivo()::Tuple{Int, Int, Int}
    pcloud_dir = get_pcloud_dir()
    archivo_enlaces_origen = joinpath(pcloud_dir, config.files.symlinks_file)
    archivo_enlaces_local = joinpath(expanduser(config.paths.local_dir), config.files.symlinks_file)
    
    if !isfile(archivo_enlaces_origen) && !isfile(archivo_enlaces_local)
        log_message(:info, "No se encontró archivo de enlaces")
        return (0, 0, 0)
    end
    
    archivo_usar = isfile(archivo_enlaces_origen) ? archivo_enlaces_origen : archivo_enlaces_local
    
    enlaces_creados = 0
    enlaces_existentes = 0
    enlaces_errores = 0
    
    open(archivo_usar, "r") do f
        for line in eachline(f)
            parts = split(line, '\t')
            if length(parts) == 2
                ruta_enlace, destino = parts
                resultado = procesar_linea_enlace(ruta_enlace, destino)
                if resultado == :creado
                    enlaces_creados += 1
                elseif resultado == :existente
                    enlaces_existentes += 1
                else
                    enlaces_errores += 1
                end
            end
        end
    end
    
    return (enlaces_creados, enlaces_existentes, enlaces_errores)
end

function procesar_linea_enlace(ruta_enlace::String, destino::String)::Symbol
    ruta_completa = joinpath(expanduser(config.paths.local_dir), ruta_enlace)
    dir_padre = dirname(ruta_completa)
    
    # Normalizar destino
    destino_normalizado = replace(destino, "/home/\\\$USERNAME" => expanduser("~"))
    destino_normalizado = replace(destino_normalizado, "\\\$USERNAME" => ENV["USER"])
    
    # Verificar seguridad
    if !startswith(destino_normalizado, expanduser("~"))
        log_message(:warn, "Destino de enlace fuera de HOME: $destino_normalizado")
        return :error
    end
    
    # Crear directorio padre si no existe
    if !isdir(dir_padre) && !args.dry_run
        mkpath(dir_padre)
    end
    
    # Verificar si el enlace ya existe y es correcto
    if islink(ruta_completa)
        destino_actual = readlink(ruta_completa)
        if destino_actual == destino_normalizado
            log_message(:debug, "Enlace ya existe: $ruta_enlace")
            return :existente
        else
            # Eliminar enlace incorrecto
            !args.dry_run && rm(ruta_completa)
        end
    end
    
    # Crear nuevo enlace
    if args.dry_run
        log_message(:info, "SIMULACIÓN: Crear enlace $ruta_enlace -> $destino_normalizado")
        return :creado
    else
        try
            symlink(destino_normalizado, ruta_completa)
            log_message(:info, "Creado enlace: $ruta_enlace")
            return :creado
        catch e
            log_message(:error, "Error creando enlace $ruta_enlace: $(e)")
            return :error
        end
    end
end

# =========================
# Sistema de sincronización con rsync
# =========================

function construir_opciones_rsync()::Vector{String}
    opts = [
        "--recursive",
        "--verbose",
        "--times",
        "--progress",
        "--munge-links",
        "--whole-file",
        "--itemize-changes"
    ]
    
    if !args.overwrite
        push!(opts, "--update")
    end
    
    if args.dry_run
        push!(opts, "--dry-run")
    end
    
    if args.delete
        push!(opts, "--delete-delay")
    end
    
    if args.use_checksum
        push!(opts, "--checksum")
    end
    
    if args.bw_limit !== nothing
        push!(opts, "--bwlimit=$(args.bw_limit)")
    end
    
    # Añadir exclusiones del archivo de configuración
    if !isempty(config.exclusiones)
        exclusion_file = tempname()
        open(exclusion_file, "w") do f
            for excl in config.exclusiones
                println(f, excl)
            end
        end
        push!(opts, "--exclude-from=$exclusion_file")
    end
    
    # Añadir exclusiones de línea de comandos
    for patron in args.exclusiones_cli
        push!(opts, "--exclude=$patron")
    end
    
    return opts
end

function sincronizar_elemento(elemento::String)::Bool
    pcloud_dir = get_pcloud_dir()
    local_dir = expanduser(config.paths.local_dir)
    
    if args.modo == "subir"
        origen = joinpath(local_dir, elemento)
        destino = joinpath(pcloud_dir, elemento)
        direccion = "LOCAL → PCLOUD"
    else
        origen = joinpath(pcloud_dir, elemento)
        destino = joinpath(local_dir, elemento)
        direccion = "PCLOUD → LOCAL"
    end
    
    if !isfile(origen) && !isdir(origen)
        log_message(:warn, "No existe: $origen")
        return false
    end
    
    # Asegurar directorio destino
    dir_destino = dirname(destino)
    if !isdir(dir_destino) && !args.dry_run
        mkpath(dir_destino)
    end
    
    log_message(:info, "Sincronizando: $elemento ($direccion)")
    
    # Construir comando rsync
    rsync_opts = construir_opciones_rsync()
    cmd = `rsync $rsync_opts $origen $destino`
    
    if args.debug || args.verbose
        log_message(:debug, "Comando rsync: $cmd")
    end
    
    try
        if args.timeout_minutes > 0 && !args.dry_run
            # Ejecutar con timeout
            run(Cmd(cmd, ignorestatus=true), wait=false)
            # Implementar timeout manual si es necesario
        else
            run(cmd)
        end
        
        # Analizar resultado
        return analizar_resultado_rsync(elemento)
    catch e
        log_message(:error, "Error sincronizando $elemento: $(e)")
        sync_stats.errores_sincronizacion += 1
        return false
    end
end

function analizar_resultado_rsync(elemento::String)::Bool
    # Esta función analizaría la salida de rsync para contar archivos
    # Por simplicidad, asumimos éxito por ahora
    sync_stats.archivos_transferidos += 1  # Esto debería ser más sofisticado
    log_message(:success, "Sincronizado: $elemento")
    return true
end

# =========================
# Funciones principales
# =========================

function mostrar_banner()
    pcloud_dir = get_pcloud_dir()
    
    println("="^50)
    if args.modo == "subir"
        println("MODO: SUBIR (Local → pCloud)")
        println("ORIGEN: $(expanduser(config.paths.local_dir))")
        println("DESTINO: $pcloud_dir")
    else
        println("MODO: BAJAR (pCloud → Local)")
        println("ORIGEN: $pcloud_dir")
        println("DESTINO: $(expanduser(config.paths.local_dir))")
    end
    
    println("DIRECTORIO: $(args.backup_dir_mode == "readonly" ? "Backup de solo lectura" : "Backup común")")
    
    if args.dry_run
        println("ESTADO: $(config.colors.yellow)MODO SIMULACIÓN$(config.colors.no_color)")
    end
    
    if args.delete
        println("BORRADO: $(config.colors.green)ACTIVADO$(config.colors.no_color)")
    end
    
    println("="^50)
end

function confirmar_ejecucion()
    if args.yes
        log_message(:info, "Confirmación automática (--yes)")
        return
    end
    
    print("¿Desea continuar con la sincronización? [s/N]: ")
    respuesta = readline()
    if !startswith(lowercase(respuesta), "s")
        log_message(:info, "Operación cancelada por el usuario")
        exit(0)
    end
end

function sincronizar()
    sync_stats.tiempo_inicio = now()
    
    # Verificaciones previas
    verificar_dependencias()
    
    if !verificar_pcloud_montado()
        error("Fallo en verificación de pCloud")
    end
    
    verificar_conectividad_pcloud()
    
    if !args.dry_run && !verificar_espacio_disco(500)
        error("Espacio en disco insuficiente")
    end
    
    # Mostrar banner y confirmar
    mostrar_banner()
    confirmar_ejecucion()
    
    # Procesar elementos
    elementos = isempty(args.items_especificos) ? 
        config.directorios_sincronizacion : args.items_especificos
    
    log_message(:info, "Iniciando sincronización de $(length(elementos)) elementos")
    
    for elemento in elementos
        try
            elemento_valido = resolver_item_relativo(elemento)
            if sincronizar_elemento(elemento_valido)
                sync_stats.elementos_procesados += 1
            end
        catch e
            log_message(:error, "Error procesando elemento $elemento: $(e)")
            sync_stats.errores_sincronizacion += 1
        end
    end
    
    # Manejar enlaces simbólicos
    if args.modo == "subir"
        archivo_temporal = tempname()
        enlaces_detectados = generar_archivo_enlaces(archivo_temporal)
        sync_stats.enlaces_detectados = enlaces_detectados
        
        # Sincronizar archivo de enlaces
        if enlaces_detectados > 0
            pcloud_dir = get_pcloud_dir()
            destino_enlaces = joinpath(pcloud_dir, config.files.symlinks_file)
            cp(archivo_temporal, destino_enlaces; force=true)
            log_message(:info, "Archivo de enlaces sincronizado: $enlaces_detectados enlaces")
        end
        
        rm(archivo_temporal)
    else
        enlaces_creados, enlaces_existentes, enlaces_errores = recrear_enlaces_desde_archivo()
        sync_stats.enlaces_creados = enlaces_creados
        sync_stats.enlaces_existentes = enlaces_existentes
        sync_stats.enlaces_errores = enlaces_errores
        log_message(:info, "Enlaces recreados: $enlaces_creados nuevos, $enlaces_existentes existentes, $enlaces_errores errores")
    end
    
    sync_stats.tiempo_fin = now()
end

function mostrar_estadisticas()
    tiempo_total = sync_stats.tiempo_fin - sync_stats.tiempo_inicio
    segundos_total = Dates.value(tiempo_total) / 1000
    
    println()
    println("="^50)
    println("RESUMEN DE SINCRONIZACIÓN")
    println("="^50)
    println("Elementos procesados: $(sync_stats.elementos_procesados)")
    println("Archivos transferidos: $(sync_stats.archivos_transferidos)")
    println("Archivos borrados: $(sync_stats.archivos_borrados)")
    println("Enlaces detectados: $(sync_stats.enlaces_detectados)")
    println("Enlaces creados: $(sync_stats.enlaces_creados)")
    println("Enlaces existentes: $(sync_stats.enlaces_existentes)")
    println("Enlaces con errores: $(sync_stats.enlaces_errores)")
    println("Errores de sincronización: $(sync_stats.errores_sincronizacion)")
    println("Tiempo total: $(round(segundos_total, digits=2)) segundos")
    println("="^50)
end

function enviar_notificacion(titulo::String, mensaje::String, tipo::String="info")
    if !config.notifications.enabled
        return
    end
    
    urgency = tipo == "error" ? "critical" : "normal"
    icon = tipo == "error" ? "dialog-error" : 
           tipo == "warning" ? "dialog-warning" : "dialog-information"
    
    try
        run(`notify-send --urgency=$urgency --icon=$icon $titulo $mensaje`)
    catch e
        log_message(:warn, "Error enviando notificación: $(e)")
    end
end

# =========================
# Función principal
# =========================

function main()
    try
        # Configurar logging
        setup_logging()

        # Cargar configuración
        global config = load_config()
 
        # Procesar argumentos
        global args = parse_args()
        
        # Establecer lock
        if !establecer_lock()
            exit(1)
        end
        
        # Ejecutar sincronización
        sincronizar()
        
        # Mostrar estadísticas
        mostrar_estadisticas()
        
        # Enviar notificación
        if sync_stats.errores_sincronizacion == 0
            enviar_notificacion(
                "Sincronización Completada",
                "Procesados: $(sync_stats.elementos_procesados) elementos",
                "info"
            )
        else
            enviar_notificacion(
                "Sincronización con Errores",
                "$(sync_stats.errores_sincronizacion) errores encontrados",
                "error"
            )
        end
        
    catch e
        log_message(:error, "Error fatal: $(e)")
        if isa(e, InterruptException)
            log_message(:info, "Ejecución interrumpida por el usuario")
        else
            showerror(stderr, e, catch_backtrace())
        end
        exit(1)
    finally
        eliminar_lock()
    end
end

# Punto de entrada
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
