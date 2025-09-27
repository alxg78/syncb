
using TOML
using FilePathsBase

export Config

struct Config
    # Rutas y directorios
    local_dir::String
    pcloud_mount_point::String
    pcloud_backup_comun::String
    pcloud_backup_readonly::String
    
    # Crypto
    local_crypto_dir::String
    remote_crypto_dir::String
    cloud_mount_check_file::String
    local_keepass_dir::String
    remote_keepass_dir::String
    local_crypto_hostname_rtva_dir::String
    remote_crypto_hostname_rtva_dir::String
    
    # Archivos
    lista_por_defecto::String
    lista_especifica_por_defecto::String
    exclusiones_file::String
    symlinks_file::String
    log_file::String
    
    # General
    lock_timeout::Int
    hostname_rtva::String
    default_timeout_minutes::Int
    
    # Listas
    directorios_sincronizacion::Vector{String}
    exclusiones::Vector{String}
    permisos_files::Vector{String}
    
    # Logging
    log_max_size_mb::Int
    log_backup_count::Int
    
    # Notificaciones
    notifications_enabled::Bool
    
    # Colores ANSI
    red::String
    green::String
    yellow::String
    blue::String
    magenta::String
    cyan::String
    white::String
    nc::String
    
    # Iconos Unicode
    check_mark::String
    cross_mark::String
    info_icon::String
    warning_icon::String
    clock_icon::String
    sync_icon::String
    error_icon::String
    success_icon::String
    
    # Datos crudos
    data::Dict{String, Any}
end

function Base.getproperty(config::Config, sym::Symbol)
    if sym == :LOCAL_DIR
        return Path(getfield(config, :local_dir))
    elseif sym == :PCLOUD_MOUNT_POINT
        return Path(getfield(config, :pcloud_mount_point))
    elseif sym == :PCLOUD_BACKUP_COMUN
        return Path(getfield(config, :pcloud_backup_comun))
    elseif sym == :PCLOUD_BACKUP_READONLY
        return Path(getfield(config, :pcloud_backup_readonly))
    elseif sym == :LOCAL_CRYPTO_DIR
        return Path(getfield(config, :local_crypto_dir))
    elseif sym == :REMOTO_CRYPTO_DIR
        return Path(getfield(config, :remote_crypto_dir))
    elseif sym == :LOCAL_KEEPASS_DIR
        return Path(getfield(config, :local_keepass_dir))
    elseif sym == :REMOTE_KEEPASS_DIR
        return Path(getfield(config, :remote_keepass_dir))
    elseif sym == :LOCAL_CRYPTO_HOSTNAME_RTVA_DIR
        return Path(getfield(config, :local_crypto_hostname_rtva_dir))
    elseif sym == :REMOTO_CRYPTO_HOSTNAME_RTVA_DIR
        return Path(getfield(config, :remote_crypto_hostname_rtva_dir))
    elseif sym == :CLOUD_MOUNT_CHECK
        return Path(getfield(config, :remote_crypto_dir)) / getfield(config, :cloud_mount_check_file)
    elseif sym == :LOG_FILE
        return Path(getfield(config, :log_file))
    else
        return getfield(config, sym)
    end
end

function Config(config_file::Union{String, Nothing}=nothing)
    config_path = find_config_file(config_file)
    
    if !isfile(config_path)
        error("No se encontró el archivo de configuración: $config_path")
    end
    
    data = TOML.parsefile(config_path)
    
    # Expandir paths
    expand_path(path) = expanduser(replace(path, r"\$(\w+)" => s -> get(ENV, s[2:end], "")))
    
    # Rutas y directorios
    paths = get(data, "paths", Dict())
    local_dir = expand_path(get(paths, "local_dir", "~"))
    pcloud_mount_point = expand_path(get(paths, "pcloud_mount_point", "~/pCloudDrive"))
    pcloud_backup_comun = expand_path(get(paths, "pcloud_backup_comun", 
        joinpath(pcloud_mount_point, "Backups", "Backup_Comun")))
    pcloud_backup_readonly = expand_path(get(paths, "pcloud_backup_readonly", 
        joinpath(pcloud_mount_point, "pCloud Backup", "feynman.sobremesa.dnf")))
    
    # Crypto
    crypto = get(data, "crypto", Dict())
    local_crypto_dir = expand_path(get(crypto, "local_crypto_dir", "~/Crypto"))
    remote_crypto_dir = expand_path(get(crypto, "remote_crypto_dir", "~/pCloudDrive/Crypto Folder"))
    cloud_mount_check_file = get(crypto, "cloud_mount_check_file", "mount.check")
    local_keepass_dir = expand_path(get(crypto, "local_keepass_dir", 
        joinpath(local_crypto_dir, "ficheros_sensibles", "Keepass2Android")))
    remote_keepass_dir = expand_path(get(crypto, "remote_keepass_dir", 
        "~/pCloudDrive/Applications/Keepass2Android"))
    local_crypto_hostname_rtva_dir = expand_path(get(crypto, "local_crypto_hostname_rtva_dir", 
        joinpath(local_crypto_dir, "ficheros_sensibles")))
    remote_crypto_hostname_rtva_dir = expand_path(get(crypto, "remote_crypto_hostname_rtva_dir", 
        joinpath(remote_crypto_dir, "ficheros_sensibles")))
    
    # Archivos
    files = get(data, "files", Dict())
    lista_por_defecto = get(files, "lista_por_defecto", "syncb_directorios.ini")
    lista_especifica_por_defecto = get(files, "lista_especifica_por_defecto", "syncb_directorios_feynman.rtva.dnf.ini")
    exclusiones_file = get(files, "exclusiones_file", "syncb_exclusiones.ini")
    symlinks_file = get(files, "symlinks_file", ".syncb_symlinks.meta")
    log_file = expand_path(get(files, "log_file", "~/syncb.log"))
    
    # General
    general = get(data, "general", Dict())
    lock_timeout = get(general, "lock_timeout", 3600)
    hostname_rtva = get(general, "hostname_rtva", "feynman.rtva.dnf")
    default_timeout_minutes = get(general, "default_timeout_minutes", 30)
    
    # Listas
    directorios_sincronizacion = get(general, "directorios_sincronizacion", String[])
    exclusiones = get(general, "exclusiones", String[])
    
    # Permisos
    permisos_ejecutables = get(data, "permisos_ejecutables", Dict())
    permisos_files = get(permisos_ejecutables, "archivos", String[])
    
    # Logging
    logging = get(data, "logging", Dict())
    log_max_size_mb = get(logging, "max_size_mb", 10)
    log_backup_count = get(logging, "backup_count", 5)
    
    # Notificaciones
    notifications = get(data, "notifications", Dict())
    notifications_enabled = get(notifications, "enabled", true)
    
    # Colores
    colors = get(data, "colors", Dict())
    red = parse_ansi_escape(get(colors, "red", "\033[0;31m"))
    green = parse_ansi_escape(get(colors, "green", "\033[0;32m"))
    yellow = parse_ansi_escape(get(colors, "yellow", "\033[1;33m"))
    blue = parse_ansi_escape(get(colors, "blue", "\033[0;34m"))
    magenta = parse_ansi_escape(get(colors, "magenta", "\033[0;35m"))
    cyan = parse_ansi_escape(get(colors, "cyan", "\033[0;36m"))
    white = parse_ansi_escape(get(colors, "white", "\033[1;37m"))
    nc = parse_ansi_escape(get(colors, "no_color", "\033[0m"))
    
    # Iconos
    icons = get(data, "icons", Dict())
    check_mark = get(icons, "check_mark", "✓")
    cross_mark = get(icons, "cross_mark", "✗")
    info_icon = get(icons, "info_icon", "ℹ")
    warning_icon = get(icons, "warning_icon", "⚠")
    clock_icon = get(icons, "clock_icon", "⏱")
    sync_icon = get(icons, "sync_icon", "🔄")
    error_icon = get(icons, "error_icon", "❌")
    success_icon = get(icons, "success_icon", "✅")
    
    return Config(
        local_dir, pcloud_mount_point, pcloud_backup_comun, pcloud_backup_readonly,
        local_crypto_dir, remote_crypto_dir, cloud_mount_check_file, local_keepass_dir, remote_keepass_dir,
        local_crypto_hostname_rtva_dir, remote_crypto_hostname_rtva_dir,
        lista_por_defecto, lista_especifica_por_defecto, exclusiones_file, symlinks_file, log_file,
        lock_timeout, hostname_rtva, default_timeout_minutes,
        directorios_sincronizacion, exclusiones, permisos_files,
        log_max_size_mb, log_backup_count, notifications_enabled,
        red, green, yellow, blue, magenta, cyan, white, nc,
        check_mark, cross_mark, info_icon, warning_icon, clock_icon, sync_icon, error_icon, success_icon,
        data
    )
end

function find_config_file(config_file::Union{String, Nothing})
    if config_file !== nothing && isfile(config_file)
        return config_file
    end
    
    default_paths = [
        "syncb_config.toml",
        "config/syncb_config.toml",
        "~/.config/syncb/syncb_config.toml",
        "/etc/syncb/syncb_config.toml"
    ]
    
    for path in default_paths
        expanded = expanduser(path)
        if isfile(expanded)
            return expanded
        end
    end
    
    error("No se encontró ningún archivo de configuración")
end

function parse_ansi_escape(color_str::String)
    return replace(color_str, "\\033" => "\033")
end

function expanduser(path::String)
    if startswith(path, "~/") || path == "~"
        home = get(ENV, "HOME", "")
        return replace(path, "~" => home)
    end
    return path
end
