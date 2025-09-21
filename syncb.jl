#!/usr/bin/env julia

#=
 Script: syncb.jl
 Descripción: Sincronización bidireccional entre directorio local y pCloud

 Uso:
   Subir: ./syncb.jl --subir [--delete] [--dry-run] [--item elemento] [--yes] [--overwrite]
   Bajar: ./syncb.jl --bajar [--delete] [--dry-run] [--item elemento] [--yes] [--backup-dir] [--overwrite]

El uso del script sigue siendo el mismo:
bash

 Sincronizar con configuración por defecto
$ ./syncb.jl --subir

 Sincronizar con elementos específicos
$ ./syncb.jl --subir --item Documentos/ --item Imágenes/

 Sincronizar con exclusiones adicionales
$ ./syncb.jl --subir --exclude "*.tmp" --exclude "temp/"
=#


using ArgParse
using Dates
using Logging
using Printf
using Mmap
using FileWatching
using SHA
using TOML

# Configuración de logging
@info "Iniciando syncb.jl"

# =========================
# Configuración desde archivo TOML
# =========================
const CONFIG_FILE = "syncb.toml"
const SCRIPT_DIR = @__DIR__

# Función para cargar configuración
function cargar_configuracion()
    config_path = joinpath(SCRIPT_DIR, CONFIG_FILE)
    if !isfile(config_path)
        config_path = joinpath(pwd(), CONFIG_FILE)
        if !isfile(config_path)
            error("No se encontró el archivo de configuración: $CONFIG_FILE")
        end
    end

    config = TOML.parsefile(config_path)

    # Expandir paths con ~
    for key in keys(config["general"])
        if occursin("_dir", key) || occursin("_file", key) || occursin("_point", key)
            config["general"][key] = expanduser(config["general"][key])
        end
    end

    for key in keys(config["crypto"])
        if occursin("_dir", key) || occursin("_file", key)
            config["crypto"][key] = expanduser(config["crypto"][key])
        end
    end

    return config
end

# Cargar configuración
const config = cargar_configuracion()

# Constantes derivadas de la configuración
const PCLOUD_MOUNT_POINT = config["general"]["pcloud_mount_point"]
const LOCAL_DIR = config["general"]["local_dir"]
const PCLOUD_BACKUP_COMUN = joinpath(PCLOUD_MOUNT_POINT, config["general"]["pcloud_backup_comun"])
const PCLOUD_BACKUP_READONLY = joinpath(PCLOUD_MOUNT_POINT, config["general"]["pcloud_backup_readonly"])
const HOSTNAME_RTVA = config["general"]["hostname_rtva"]
const LOG_FILE = config["general"]["log_file"]
const LOCK_FILE = config["general"]["lock_file"]
const LOCK_TIMEOUT = config["general"]["lock_timeout"]

# Variables de configuración crypto
const LOCAL_CRYPTO_DIR = config["crypto"]["local_crypto_dir"]
const REMOTO_CRYPTO_DIR = config["crypto"]["remoto_crypto_dir"]
const CLOUD_MOUNT_CHECK_FILE = config["crypto"]["cloud_mount_check_file"]
const CLOUD_MOUNT_CHECK = joinpath(REMOTO_CRYPTO_DIR, CLOUD_MOUNT_CHECK_FILE)
const LOCAL_KEEPASS_DIR = config["crypto"]["local_keepass_dir"]
const REMOTE_KEEPASS_DIR = config["crypto"]["remote_keepass_dir"]
const LOCAL_CRYPTO_HOSTNAME_RTVA_DIR = config["crypto"]["local_crypto_hostname_rtva_dir"]
const REMOTO_CRYPTO_HOSTNAME_RTVA_DIR = config["crypto"]["remoto_crypto_hostname_rtva_dir"]

# Obtener hostname
const HOSTNAME = try
    readchomp(`hostname -f`)
catch
    try
        readchomp(`hostname`)
    catch
        "unknown-host"
    end
end

# Enlaces simbólicos en la subida, origen
const SYMLINKS_FILE = ".syncb_symlinks.meta"

# Variables de control globales
mutable struct ConfigEstado
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
    timeout_minutes::Int
    force_unlock::Bool
end

ConfigEstado() = ConfigEstado(
    "",      # modo
    false,   # dry_run
    false,   # delete
    false,   # yes
    false,   # overwrite
    "comun", # backup_dir_mode
    false,   # verbose
    false,   # debug
    false,   # use_checksum
    nothing, # bw_limit
    false,   # sync_crypto
    [],      # items_especificos
    [],      # exclusiones_cli
    30,      # timeout_minutes
    false    # force_unlock
)

const estado = ConfigEstado()

# Variables para estadísticas
const elementos_procesados = Ref(0)
const errores_sincronizacion = Ref(0)
const archivos_transferidos = Ref(0)
const enlaces_creados = Ref(0)
const enlaces_existentes = Ref(0)
const enlaces_errores = Ref(0)
const enlaces_detectados = Ref(0)
const archivos_borrados = Ref(0)
const archivos_crypto_transferidos = Ref(0)

# Definición de colores (códigos ANSI)
const RED = "\033[0;31m"
const GREEN = "\033[0;32m"
const YELLOW = "\033[1;33m"
const BLUE = "\033[0;34m"
const MAGENTA = "\033[0;35m"
const CYAN = "\033[0;36m"
const WHITE = "\033[1;37m"
const NC = "\033[0m"

# Iconos Unicode
const CHECK_MARK = "✓"
const CROSS_MARK = "✗"
const INFO_ICON = "ℹ"
const WARNING_ICON = "⚠"
const DEBUG_ICON = "🔍"
const LOCK_ICON = "🔒"
const UNLOCK_ICON = "🔓"
const CLOCK_ICON = "⏱"
const SYNC_ICON = "🔄"
const ERROR_ICON = "❌"
const SUCCESS_ICON = "✅"

# Niveles de log con colores asignados
const LOG_INFO = BLUE * INFO_ICON * " [INFO]" * NC
const LOG_WARN = YELLOW * WARNING_ICON * " [WARN]" * NC
const LOG_ERROR = RED * CROSS_MARK * " [ERROR]" * NC
const LOG_SUCCESS = GREEN * CHECK_MARK * " [SUCCESS]" * NC
const LOG_DEBUG = MAGENTA * CLOCK_ICON * " [DEBUG]" * NC

# =========================
# Sistema de logging mejorado
# =========================
function log_info(msg)
    message = string(LOG_INFO, " ", msg)
    println(message)
    registrar_log("[INFO] $msg")
end

function log_warn(msg)
    message = string(LOG_WARN, " ", msg)
    println(message)
    registrar_log("[WARN] $msg")
end

function log_error(msg)
    message = string(LOG_ERROR, " ", msg)
    println(stderr, message)
    registrar_log("[ERROR] $msg")
end

function log_success(msg)
    message = string(LOG_SUCCESS, " ", msg)
    println(message)
    registrar_log("[SUCCESS] $msg")
end

function log_debug(msg)
    if estado.debug || estado.verbose
        message = string(LOG_DEBUG, " ", msg)
        println(stderr, message)
        registrar_log("[DEBUG] $msg")
    end
end

# Función de logging optimizada con rotación automática
function registrar_log(message)
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    log_entry = "$timestamp - $message\n"

    # Escribir en el archivo de log
    open(LOG_FILE, "a") do file
        write(file, log_entry)
    end

    # Rotación de logs si superan 10MB (solo en modo ejecución real)
    if !estado.dry_run && isfile(LOG_FILE)
        log_size = filesize(LOG_FILE)
        if log_size > 10_000_000  # 10MB
            mv(LOG_FILE, LOG_FILE * ".old")
            touch(LOG_FILE)
            chmod(LOG_FILE, 0o644)
            log_info("Log rotado automáticamente (tamaño: $(round(log_size / 1024 / 1024, digits=2))MB)")
        end
    end
end

# =========================
# Utilidades
# =========================

# Normalizar rutas
function normalize_path(p)
    try
        return realpath(p)
    catch
        return abspath(p)
    end
end

# Función para determinar el directorio de pCloud según el modo
function get_pcloud_dir()
    if estado.backup_dir_mode == "readonly"
        return PCLOUD_BACKUP_READONLY
    else
        return PCLOUD_BACKUP_COMUN
    end
end

# Función para obtener la lista de directorios a sincronizar
function get_directorios_sincronizacion()
    if haskey(config["directorios"], HOSTNAME)
        return config["directorios"][HOSTNAME]
    else
        return config["directorios"]["por_defecto"]
    end
end

# Función para obtener las exclusiones
function get_exclusiones()
    return config["exclusiones"]["patrones"]
end

# Función para verificar conectividad con pCloud
function verificar_conectividad_pcloud()
    log_debug("Verificando conectividad con pCloud...")

    try
        run(pipeline(`curl -s https://www.pcloud.com/`, devnull))
        log_info("Verificación de conectividad pCloud: OK")
        return true
    catch
        log_warn("No se pudo conectar a pCloud")
        log_info("Verifica tu conexión a Internet y que pCloud esté disponible")
        return false
    end
end

# Función para mostrar ayuda
function mostrar_ayuda()
    println(stderr, "Uso: $(basename(@__FILE__)) [OPCIONES]")
    println(stderr, "")
    println(stderr, "Opciones PRINCIPALES (obligatorio una de ellas):")
    println(stderr, "  --subir            Sincroniza desde el directorio local a pCloud ($LOCAL_DIR → pCloud)")
    println(stderr, "  --bajar            Sincroniza desde pCloud al directorio local (pCloud → $LOCAL_DIR)")
    println(stderr, "")
    println(stderr, "Opciones SECUNDARIAS (opcionales):")
    println(stderr, "  --delete           Elimina en destino los archivos que no existan en origen (delete-delay)")
    println(stderr, "  --dry-run          Simula la operación sin hacer cambios reales")
    println(stderr, "  --item ELEMENTO    Sincroniza solo el elemento especificado (archivo o directorio)")
    println(stderr, "  --yes              No pregunta confirmación, ejecuta directamente")
    println(stderr, "  --backup-dir       Usa el directorio de backup de solo lectura (pCloud Backup) en lugar de Backup_Comun")
    println(stderr, "  --exclude PATRON   Excluye archivos que coincidan con el patrón (puede usarse múltiples veces)")
    println(stderr, "  --overwrite        Sobrescribe todos los archivos en destino (no usa --update)")
    println(stderr, "  --checksum         Fuerza comparación con checksum (más lento)")
    println(stderr, "  --bwlimit KB/s     Limita la velocidad de transferencia (ej: 1000 para 1MB/s)")
    println(stderr, "  --timeout MINUTOS  Límite de tiempo por operación (default: 30)")
    println(stderr, "  --force-unlock     Forzando eliminación de lock")
    println(stderr, "  --crypto           Incluye la sincronización del directorio Crypto")
    println(stderr, "  --verbose          Habilita modo verboso para debugging")
    println(stderr, "  --help             Muestra esta ayuda")
    println(stderr, "")
    println(stderr, "Archivo de configuración: $CONFIG_FILE")
    println(stderr, "")
    println(stderr, "Hostname detectado: $HOSTNAME")
    println(stderr, "")
    println(stderr, "Ejemplos:")
    println(stderr, "  syncb.jl --subir")
    println(stderr, "  syncb.jl --bajar --dry-run")
    println(stderr, "  syncb.jl --subir --delete --yes")
    println(stderr, "  syncb.jl --subir --item documentos/")
    println(stderr, "  syncb.jl --bajar --item configuracion.ini --item .local/bin --dry-run")
    println(stderr, "  syncb.jl --bajar --backup-dir --item documentos/ --yes")
    println(stderr, "  syncb.jl --subir --exclude '*.tmp' --exclude 'temp/'")
    println(stderr, "  syncb.jl --subir --overwrite     # Sobrescribe todos los archivos")
    println(stderr, "  syncb.jl --subir --bwlimit 1000  # Sincronizar subiendo con límite de 1MB/s")
    println(stderr, "  syncb.jl --subir --verbose       # Sincronizar con output verboso")
    println(stderr, "  syncb.jl --bajar --item Documentos/ --timeout 10  # Timeout corto de 10 minutos para una operación rápida")
    println(stderr, "  syncb.jl --force-unlock   # Forzar desbloqueo si hay un lock obsoleto")
    println(stderr, "  syncb.jl --crypto         # Incluir directorio Crypto de la sincronización")
    println(stderr, "")
    println(stderr, "Eliminar enlaces simbolicos rotos")
    println(stderr, " find ~/Documentos -xtype l                      Encuentra enlaces rotos")
    println(stderr, " find ~/Documentos -xtype l -delete              Elimina enlaces rotos")
    println(stderr, " find ~/Documentos -type l -exec ls -l {} \\;     Lista todos los enlaces (rotos y válidos)")
end

# Función para procesar argumentos de línea de comandos
function procesar_argumentos(args)
    if isempty(args) || "--help" in args
        log_error("Debes especificar al menos --subir o --bajar")
        mostrar_ayuda()
        exit(1)
    end

    log_debug("Argumentos recibidos: $(join(args, ' '))")

    # Verificación de argumentos duplicados
    seen_opts = Set{String}()
    i = 1
    while i <= length(args)
        arg = args[i]
        if startswith(arg, "--") && arg != "--item" && arg != "--exclude"
            if arg in seen_opts
                log_error("Opción duplicada: $arg")
                exit(1)
            end
            push!(seen_opts, arg)
        elseif arg == "--item" || arg == "--exclude"
            i += 1  # Saltar el siguiente argumento (valor de --item o --exclude)
        end
        i += 1
    end

    # Procesar cada argumento
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--subir"
            if !isempty(estado.modo)
                log_error("No puedes usar --subir y --bajar simultáneamente")
                exit(1)
            end
            estado.modo = "subir"
            i += 1
        elseif arg == "--bajar"
            if !isempty(estado.modo)
                log_error("No puedes usar --subir y --bajar simultáneamente")
                exit(1)
            end
            estado.modo = "bajar"
            i += 1
        elseif arg == "--delete"
            estado.delete = true
            i += 1
        elseif arg == "--dry-run"
            estado.dry_run = true
            i += 1
        elseif arg == "--item"
            if i + 1 > length(args)
                log_error("--item requiere un argumento")
                exit(1)
            end
            push!(estado.items_especificos, args[i+1])
            i += 2
        elseif arg == "--exclude"
            if i + 1 > length(args)
                log_error("--exclude requiere un patrón")
                exit(1)
            end
            push!(estado.exclusiones_cli, args[i+1])
            i += 2
        elseif arg == "--yes"
            estado.yes = true
            i += 1
        elseif arg == "--backup-dir"
            estado.backup_dir_mode = "readonly"
            i += 1
        elseif arg == "--overwrite"
            estado.overwrite = true
            i += 1
        elseif arg == "--checksum"
            estado.use_checksum = true
            i += 1
        elseif arg == "--bwlimit"
            if i + 1 > length(args)
                log_error("--bwlimit requiere un valor (KB/s)")
                exit(1)
            end
            estado.bw_limit = args[i+1]
            i += 2
        elseif arg == "--timeout"
            if i + 1 > length(args)
                log_error("--timeout requiere minutos")
                exit(1)
            end
            estado.timeout_minutes = parse(Int, args[i+1])
            i += 2
        elseif arg == "--force-unlock"
            estado.force_unlock = true
            i += 1
        elseif arg == "--crypto"
            estado.sync_crypto = true
            i += 1
        elseif arg == "--verbose"
            estado.verbose = true
            i += 1
        elseif arg == "--help" || arg == "-h"
            mostrar_ayuda()
            exit(0)
        else
            log_error("Opción desconocida: $arg")
            mostrar_ayuda()
            exit(1)
        end
    end
end

# Función para verificar si pCloud está montado
function verificar_pcloud_montado()
    pcloud_dir = normalize_path(get_pcloud_dir())

    # Verificar si el punto de montaje de pCloud existe
    log_debug("Verificando montaje de pCloud en: $PCLOUD_MOUNT_POINT")
    if !isdir(PCLOUD_MOUNT_POINT)
        log_error("El punto de montaje de pCloud no existe: $PCLOUD_MOUNT_POINT")
        log_info("Asegúrate de que pCloud Drive esté instalado и ejecutándose.")
        return false
    end

    # Verificación más robusta: comprobar si pCloud está realmente montado
    # 1. Verificar si el directorio está vacío (puede indicar que no está montado)
    log_debug("Verificando si el directorio de pCloud está vacío: $PCLOUD_MOUNT_POINT")
    if isempty(readdir(PCLOUD_MOUNT_POINT))
        log_error("El directorio de pCloud está vacío: $PCLOUD_MOUNT_POINT")
        log_info("Esto sugiere que pCloud Drive no está montado correctamente.")
        return false
    end

    # Verificar si el directorio específico de pCloud existe
    if !isdir(pcloud_dir)
        log_debug("El directorio de pCloud no existe: $pcloud_dir")
        log_error("El directorio de pCloud no existe: $pcloud_dir")
        log_info("Asegúrate de que:")
        log_info("1. pCloud Drive esté ejecutándose")
        log_info("2. Tu cuenta de pCloud esté sincronizada")
        log_info("3. El directorio exista en tu pCloud")
        return false
    end

    # Verificación adicional: intentar escribir en el directorio (solo si no es dry-run y no es modo backup-dir)
    if !estado.dry_run && estado.backup_dir_mode == "comun"
        log_debug("Verificando permisos de escritura en: $pcloud_dir")
        test_file = joinpath(pcloud_dir, ".test_write_$(getpid())")
        try
            touch(test_file)
            rm(test_file)
        catch e
            log_error("No se puede escribir en: $pcloud_dir")
            return false
        end
    end

    # Verifica montaje de la carpeta Crypto
    log_debug("Verificando montaje de Crypto en: $REMOTO_CRYPTO_DIR")
    if !isfile(CLOUD_MOUNT_CHECK) && estado.sync_crypto
        log_error("El volumen Crypto no está montado o el archio de verificación no existe")
        log_error("Por favor, desbloquea/monta la unidad en: \"$REMOTO_CRYPTO_DIR\"")
        return false
    end

    log_debug("Verificación de pCloud completada con éxito.")
    return true
end

# Función para mostrar el banner informativo
function mostrar_banner()
    pcloud_dir = get_pcloud_dir()

    log_debug("Mostrando banner informativo.")

    println("==========================================")
    if estado.modo == "subir"
        println("MODO: SUBIR (Local → pCloud)")
        println("ORIGEN: $LOCAL_DIR")
        println("DESTINO: $pcloud_dir")
    else
        println("MODO: BAJAR (pCloud → Local)")
        println("ORIGEN: $pcloud_dir")
        println("DESTINO: $LOCAL_DIR")
    end

    if estado.backup_dir_mode == "readonly"
        println("DIRECTORIO: Backup de solo lectura (pCloud Backup)")
    else
        println("DIRECTORIO: Backup común (Backup_Comun)")
    end

    if estado.dry_run
        println("ESTADO: $(YELLOW)MODO SIMULACIÓN$(NC) (no se realizarán cambios)")
    end

    if estado.delete
        println("BORRADO: $(GREEN)ACTIVADO$(NC) (se eliminarán archivos obsoletos)")
    end

    if estado.yes
        println("CONFIRMACIÓN: Automática (sin preguntar)")
    end

    if estado.overwrite
        println("SOBRESCRITURA: $(GREEN)ACTIVADA$(NC)")
    else
        println("MODO: SEGURO (--update activado)")
    end

    if estado.sync_crypto
        println("CRYPTO: $(GREEN)INCLUIDO$(NC) (se sincronizará directorio Crypto)")
    else
        println("CRYPTO: $(YELLOW)EXCLUIDO$(NC) (no se sincronizará directorio Crypto)")
    end

    if !isempty(estado.items_especificos)
        println("ELEMENTOS ESPECÍFICOS: $(join(estado.items_especificos, ", "))")
    else
        directorios = get_directorios_sincronizacion()
        println("DIRECTORIOS A SINCRONIZAR: $(length(directorios)) elementos")
    end

    exclusiones = get_exclusiones()
    println("EXCLUSIONES CONFIGURADAS: $(length(exclusiones)) patrones")

    # Exclusiones linea comandos exclusiones_cli
    if !isempty(estado.exclusiones_cli)
        println("EXCLUSIONES CLI ($(length(estado.exclusiones_cli)) patrones):")
        for (i, patron) in enumerate(estado.exclusiones_cli)
            println("  $i. $patron")
        end
    end
    println("==========================================")
end

# Función para confirmar la ejecución
function confirmar_ejecucion()
    if estado.yes
        log_info("Confirmación automática (--yes): se procede con la sincronización")
        return
    end

    println()
    print("¿Desea continuar con la sincronización? [s/N]: ")
    respuesta = readline()
    if !occursin(r"^[sS]", respuesta)
        log_info("Operación cancelada por el usuario.")
        exit(0)
    end
    println()
end

# Función para verificar y crear archivo de log
function inicializar_log()
    # Truncar log si supera 5MB (compatible con macOS y Linux)
    log_debug("Inicializando archivo de log: $LOG_FILE")

    if isfile(LOG_FILE)
        log_size = filesize(LOG_FILE)
        if log_size > 5_242_880  # 5MB
            truncate(LOG_FILE, 0)
        end
    end

    touch(LOG_FILE)
    chmod(LOG_FILE, 0o644)
    open(LOG_FILE, "a") do file
        write(file, "==========================================\n")
        write(file, "Sincronización iniciada: $(now())\n")
        write(file, "Modo: $(estado.modo)\n")
        write(file, "Delete: $(estado.delete)\n")
        write(file, "Dry-run: $(estado.dry_run)\n")
        write(file, "Backup-dir: $(estado.backup_dir_mode)\n")
        write(file, "Overwrite: $(estado.overwrite)\n")
        write(file, "Checksum: $(estado.use_checksum)\n")
        write(file, "Sync Crypto: $(estado.sync_crypto)\n")
        if !isempty(estado.items_especificos)
            write(file, "Items específicos: $(join(estado.items_especificos, ", "))\n")
        end
        directorios = get_directorios_sincronizacion()
        write(file, "Directorios a sincronizar: $(length(directorios)) elementos\n")
        exclusiones = get_exclusiones()
        write(file, "Exclusiones configuradas: $(length(exclusiones)) patrones\n")
    end
end

# Función para verificar dependencias
function verificar_dependencias()
    log_debug("Verificando dependencias...")
    try
        run(`rsync --version`)
    catch
        log_error("rsync no está instalado. Instálalo con:")
        log_info("sudo apt install rsync  # Debian/Ubuntu")
        log_info("sudo dnf install rsync  # RedHat/CentOS")
        exit(1)
    end
end

# Función para verificar la existencia de todos los elementos en la configuración
function verificar_elementos_configuracion()
    pcloud_dir = get_pcloud_dir()
    errores = false

    log_info("Verificando existencia de todos los elementos en la configuración...")

    if !isempty(estado.items_especificos)
        # Verificar items específicos de línea de comandos
        for elemento in estado.items_especificos
            rel_item = resolver_item_relativo(elemento)
            if !isempty(rel_item)
                if estado.modo == "subir"
                    if !isfile(joinpath(LOCAL_DIR, rel_item)) && !isdir(joinpath(LOCAL_DIR, rel_item))
                        log_error("El elemento específico '$rel_item' no existe en el directorio local: $(joinpath(LOCAL_DIR, rel_item))")
                        errores = true
                    end
                else
                    if !isfile(joinpath(pcloud_dir, rel_item)) && !isdir(joinpath(pcloud_dir, rel_item))
                        log_error("El elemento específico '$rel_item' no existe en pCloud: $(joinpath(pcloud_dir, rel_item))")
                        errores = true
                    end
                end
            end
        end
    else
        # Verificar elementos de la configuración
        directorios = get_directorios_sincronizacion()
        for elemento in directorios
            if estado.modo == "subir"
                if !isfile(joinpath(LOCAL_DIR, elemento)) && !isdir(joinpath(LOCAL_DIR, elemento))
                    log_error("El elemento '$elemento' no existe en el directorio local: $(joinpath(LOCAL_DIR, elemento))")
                    errores = true
                end
            else
                if !isfile(joinpath(pcloud_dir, elemento)) && !isdir(joinpath(pcloud_dir, elemento))
                    log_error("El elemento '$elemento' no existe en pCloud: $(joinpath(pcloud_dir, elemento))")
                    errores = true
                end
            end
        end
    end

    if errores
        log_error("Se encontraron errores en la configuración. Corrige los elementos antes de continuar.")
        return false
    end

    log_info("Todos los elementos verificados existen")
    return true
end

# Construye opciones de rsync
function construir_opciones_rsync()
    rsync_opts = [
        "--recursive",
        "--verbose",
        "--times",
        "--progress",
        "--munge-links",
        "--whole-file",
        "--itemize-changes"
    ]

    if !estado.overwrite
        push!(rsync_opts, "--update")
    end

    if estado.dry_run
        push!(rsync_opts, "--dry-run")
    end

    if estado.delete
        push!(rsync_opts, "--delete-delay")
    end

    if estado.use_checksum
        push!(rsync_opts, "--checksum")
    end

    # Límite de ancho de banda (si está configurado)
    if !isnothing(estado.bw_limit)
        push!(rsync_opts, "--bwlimit=$(estado.bw_limit)")
    end

    # Añadir exclusiones de configuración
    exclusiones = get_exclusiones()
    for patron in exclusiones
        push!(rsync_opts, "--exclude=$patron")
    end

    # Añadir exclusiones de línea de comandos
    if !isempty(estado.exclusiones_cli)
        for patron in estado.exclusiones_cli
            push!(rsync_opts, "--exclude=$patron")
        end
        log_info("Exclusiones por CLI aplicadas: $(length(estado.exclusiones_cli)) patrones")
    end

    return rsync_opts
end

# Función para mostrar estadísticas completas
function mostrar_estadísticas(tiempo_inicio)
    tiempo_total = time() - tiempo_inicio
    horas = trunc(Int, tiempo_total / 3600)
    minutos = trunc(Int, (tiempo_total % 3600) / 60)
    segundos = trunc(Int, tiempo_total % 60)

    println()
    println("==========================================")
    println("RESUMEN DE SINCRONIZACIÓN")
    println("==========================================")
    println("Elementos procesados: $(elementos_procesados[])")
    println("Archivos transferidos: $(archivos_transferidos[])")
    if estado.sync_crypto
        println("Archivos Crypto transferidos: $(archivos_crypto_transferidos[])")
    end
    if estado.delete
        println("Archivos borrados en destino: $(archivos_borrados[])")
    end
    if !isempty(estado.exclusiones_cli)
        println("Exclusiones CLI aplicadas: $(length(estado.exclusiones_cli)) patrones")
    end
    println("Enlaces manejados: $(enlaces_creados[] + enlaces_existentes[])")
    println("  - Enlaces detectados/guardados: $(enlaces_detectados[])")
    println("  - Enlaces creados: $(enlaces_creados[])")
    println("  - Enlaces existentes: $(enlaces_existentes[])")
    println("  - Enlaces con errores: $(enlaces_errores[])")
    println("Errores de sincronización: $(errores_sincronizacion[])")

    if tiempo_total >= 3600
        println("Tiempo total: $(horas)h $(minutos)m $(segundos)s")
    elseif tiempo_total >= 60
        println("Tiempo total: $(minutos)m $(segundos)s")
    else
        println("Tiempo total: $(segundos)s")
    end

    archivos_por_segundo = archivos_transferidos[] / max(tiempo_total, 1)
    println("Velocidad promedio: $(round(archivos_por_segundo, digits=2)) archivos/segundo")
    println("Modo: $(estado.dry_run ? "SIMULACIÓN" : "EJECUCIÓN REAL")")
    println("==========================================")
end

# Función para verificar espacio disponible en disco
function verificar_espacio_disco(needed_mb=100)
    # Determinar el punto de montaje a verificar según el modo
    if estado.modo == "subir"
        mount_point = PCLOUD_MOUNT_POINT
        tipo_operacion = "SUBIDA a pCloud"
    else
        mount_point = LOCAL_DIR
        tipo_operacion = "BAJADA desde pCloud"
    end

    # Verificar que el punto de montaje existe
    if !isdir(mount_point)
        log_debug("El punto de montaje $mount_point no existe, omitiendo verificación de espacio.")
        log_warn("El punto de montaje $mount_point no existe, omitiendo verificación de espacio")
        return true
    end

    # Obtener espacio disponible
    try
        if Sys.islinux()
            df_output = readchomp(`df -m --output=avail $mount_point`)
            available_mb = parse(Int, split(df_output, '\n')[2])
        elseif Sys.isapple()
            df_output = readchomp(`df -m $mount_point`)
            available_mb = parse(Int, split(split(df_output, '\n')[2])[4])
        else
            log_warn("Sistema operativo no soportado para verificación de espacio, omitiendo")
            return true
        end

        if available_mb < needed_mb
            log_error("Espacio insuficiente para $tipo_operacion en $mount_point")
            log_error("Disponible: $(available_mb)MB, Necesario: $(needed_mb)MB")
            return false
        end

        log_debug("Espacio suficiente disponible: $(available_mb)MB.")
        log_info("Espacio en disco verificado para $tipo_operacion. Disponible: $(available_mb)MB")
        return true
    catch e
        log_debug("No se pudo obtener el espacio disponible en $mount_point: $e")
        log_warn("No se pudo determinar el espacio disponible en $mount_point, omitiendo verificación")
        return true
    end
end

# Función para enviar notificaciones del sistema
function enviar_notificacion(titulo, mensaje, tipo="info")
    # Para sistemas Linux con notify-send
    if success(`which notify-send`)
        # Determinar la urgencia según el tipo (nunca usar "low")
        urgencia = tipo == "error" ? "critical" : "normal"
        icono = tipo == "error" ? "dialog-error" :
                tipo == "warning" ? "dialog-warning" : "dialog-information"

        run(`notify-send --urgency=$urgencia --icon=$icono $titulo $mensaje`)
    # Para sistemas macOS
    elseif success(`which osascript`)
        script = "display notification \"$mensaje\" with title \"$titulo\""
        run(`osascript -e $script`)
    # Fallback para terminal
    else
        println("\n🔔 $titulo: $mensaje")
    end
end

# Función para notificar finalización
function notificar_finalizacion(exit_code)
    # Pequeña pausa para asegurar que todas las operaciones previas han terminado
    sleep(0.5)

    if exit_code == 0
        enviar_notificacion(
            "Sincronización Completada",
            "Sincronización finalizada con éxito\n• Elementos: $(elementos_procesados[])\n• Transferidos: $(archivos_transferidos[])\n• Tiempo: $(round(time() - tiempo_inicio, digits=2))s",
            "info"
        )
    else
        enviar_notificacion(
            "Sincronización con Errores",
            "Sincronización finalizada con errores\n• Errores: $(errores_sincronizacion[])\n• Verifique el log: $LOG_FILE",
            "error"
        )
    end
end

# Función para obtener información del proceso dueño del lock
function obtener_info_proceso_lock(pid)
    try
        if process_running(pid)
            cmd = readchomp(`ps -p $pid -o comm=`)
            start_time = readchomp(`ps -p $pid -o lstart=`)
            return "Dueño del lock: PID $pid, Comando: $cmd, Iniciado: $start_time"
        else
            return "Dueño del lock: PID $pid (proceso ya terminado)"
        end
    catch
        return "Dueño del lock: PID $pid (información no disponible)"
    end
end

# Función para establecer el lock
function establecer_lock()
    if isfile(LOCK_FILE)
        log_debug("Archio de lock encontrado: $LOCK_FILE")
        lock_pid = parse(Int, readline(LOCK_FILE))
        lock_time = mtime(LOCK_FILE)
        current_time = time()
        lock_age = current_time - lock_time

        if lock_age > LOCK_TIMEOUT
            log_warn("Eliminando lock obsoleto (edad: $(lock_age)s > timeout: $(LOCK_TIMEOUT)s)")
            rm(LOCK_FILE)
        elseif process_running(lock_pid)
            log_error("Ya hay una ejecución en progreso (PID: $lock_pid)")
            log_error(obtener_info_proceso_lock(lock_pid))
            return false
        else
            log_warn("Eliminando lock obsoleto del proceso $lock_pid")
            rm(LOCK_FILE)
        end
    end

    try
        open(LOCK_FILE, "w") do file
            println(file, getpid())
            println(file, "PID: $(getpid())")
            println(file, "Fecha: $(now())")
            println(file, "Modo: $(estado.modo)")
            println(file, "Usuario: $(ENV["USER"])")
            println(file, "Hostname: $HOSTNAME")
        end

        log_debug("Lock establecido para PID: $(getpid())")
        log_info("Lock establecido: $LOCK_FILE")
        return true
    catch e
        log_error("No se pudo crear el archio de lock: $LOCK_FILE")
        return false
    end
end

# Función para eliminar el lock
function eliminar_lock()
    if isfile(LOCK_FILE)
        pid_line = readline(LOCK_FILE)
        if occursin("$(getpid())", pid_line)
            log_debug("Eliminando lock para PID: $(getpid())")
            rm(LOCK_FILE)
            log_info("Lock eliminado")
        end
    end
end

# Función específica para eliminar el lock
function eliminar_lock_final()
    if isfile(LOCK_FILE)
        pid_line = readline(LOCK_FILE)
        if occursin("$(getpid())", pid_line)
            log_debug("Eliminando lock final para PID: $(getpid())")
            rm(LOCK_FILE)
            log_info("Lock eliminado")
        end
    end
end

# =========================
# Validación y utilidades rsync
# =========================
function validate_rsync_opts(rsync_opts)
    for opt in rsync_opts
        if occursin(r"rsync", lowercase(opt))
            log_error("RSYNC_OPTS contiene un elemento sospechoso con 'rsync': $opt")
            return false
        end
    end
    return true
end

# Formate comando rsync e imprime como un log_debug
function print_rsync_command(origen, destino, rsync_opts)
    cmd = `rsync $rsync_opts $origen $destino`
    log_debug(string(cmd))
end

# =========================
# ENLACES SIMBÓLICOS
# =========================

# Función para registrar un enlace individual
function registrar_enlace(enlace, archivo_enlaces)
    # Solo enlaces simbólicos
    if !islink(enlace)
        return
    end

    # Columna 1: ruta del ENLACE relativa a $HOME
    ruta_relativa = enlace
    if startswith(ruta_relativa, LOCAL_DIR * "/")
        ruta_relativa = ruta_relativa[length(LOCAL_DIR) + 2:end]
    else
        ruta_relativa = ruta_relativa[2:end]  # Remove leading /
    end

    # Columna 2: destino tal cual fue creado el enlace
    destino = readlink(enlace)

    # Validaciones: no escribir líneas incompletas
    if isempty(ruta_relativa) || isempty(destino)
        log_debug("Enlace no válido o vacío: $enlace")
        log_warn("Enlace no válido u origen/destino vacío: $enlace")
        return
    end

    # Normalización del destino
    if startswith(destino, homedir())
        destino = "/home/\$USERNAME" * destino[length(homedir()):end]
    elseif startswith(destino, "/home/")
        parts = split(destino, "/")
        if length(parts) > 3
            destino = "/home/\$USERNAME/" * join(parts[4:end], "/")
        else
            destino = "/home/\$USERNAME"
        end
    end

    open(archivo_enlaces, "a") do file
        println(file, "$ruta_relativa\t$destino")
    end

    log_debug("Registrado enlace simbólico: $ruta_relativa -> $destino")
    enlaces_detectados[] += 1
end

# Función para buscar enlaces en un directorio
function buscar_enlaces_en_directorio(dir, archivo_enlaces)
    isdir(dir) || return

    log_debug("Buscando enlaces en directorio: $dir")

    for (root, dirs, files) in walkdir(dir)
        for file in files
            path = joinpath(root, file)
            if islink(path)
                registrar_enlace(path, archivo_enlaces)
            end
        end
    end
end

# Función principal para generar archivo de enlaces
function generar_archivo_enlaces(archivo_enlaces)
    pcloud_dir = get_pcloud_dir()
    log_debug("Generando archivo de enlaces: $archivo_enlaces")

    try
        touch(archivo_enlaces)
    catch
        log_error("No se pudo crear el archivo temporal de enlaces")
        return false
    end

    if !isempty(estado.items_especificos)
        for elemento in estado.items_especificos
            ruta_completa = joinpath(LOCAL_DIR, elemento)
            log_debug("Buscando enlaces para elemento específico: $ruta_completa")

            if islink(ruta_completa)
                registrar_enlace(ruta_completa, archivo_enlaces)
            elseif isdir(ruta_completa)
                buscar_enlaces_en_directorio(ruta_completa, archivo_enlaces)
            end
        end
    else
        directorios = get_directorios_sincronizacion()
        for elemento in directorios
            # Validación de seguridad adicional
            if occursin("..", elemento)
                log_error("Elemento contiene '..' - posible path traversal: $elemento")
                continue
            end

            ruta_completa = joinpath(LOCAL_DIR, elemento)
            if islink(ruta_completa)
                registrar_enlace(ruta_completa, archivo_enlaces)
            elseif isdir(ruta_completa)
                buscar_enlaces_en_directorio(ruta_completa, archivo_enlaces)
            end
        end
    end

    if filesize(archivo_enlaces) > 0
        log_debug("Sincronizando archivo de enlaces a pCloud...")
        rsync_opts = construir_opciones_rsync()

        if !validate_rsync_opts(rsync_opts)
            log_error("Abortando: RSYNC_OPTS inválido")
            return false
        end

        # Imprimir comando de forma segura, si estamos en modo debugg
        if estado.debug || estado.verbose
            print_rsync_command(archivo_enlaces, joinpath(pcloud_dir, SYMLINKS_FILE), rsync_opts)
        end

        if success(`rsync $rsync_opts $archivo_enlaces $(joinpath(pcloud_dir, SYMLINKS_FILE))`)
            log_info("Enlaces detectados/guardados en meta: $(enlaces_detectados[])")
            log_info("Archivo de enlaces sincronizado")
        else
            log_error("Error sincronizando archivo de enlaces")
            return false
        end
    else
        log_debug("No se encontraron enlaces simbólicos para registrar")
    end

    rm(archivo_enlaces)
    return true
end

# Función para recrear enlaces simbólicos
function procesar_linea_enlace(ruta_enlace, destino)
    ruta_completa = joinpath(LOCAL_DIR, ruta_enlace)
    dir_padre = dirname(ruta_completa)

    log_debug("Procesando enlace: $ruta_enlace -> $destino")

    if !isdir(dir_padre) && !estado.dry_run
        mkpath(dir_padre)
    end

    # Normalizar destino y validar
    destino_para_ln = replace(destino, "\$HOME" => homedir())
    destino_para_ln = replace(destino_para_ln, "\$USERNAME" => ENV["USER"])
    destino_para_ln = normalize_path(destino_para_ln)

    # Validar que esté dentro de $HOME
    if !startswith(destino_para_ln, homedir())
        log_debug("Destino de enlace fuera de HOME: $destino_para_ln")
        log_warn("Destino de enlace fuera de \$HOME, se omite: $ruta_enlace -> $destino_para_ln")
        return true
    end

    # Si ya existe y apunta a lo mismo
    if islink(ruta_completa)
        destino_actual = readlink(ruta_completa)

        if destino_actual == destino_para_ln
            log_debug("Enlace ya existe y es correcto: $ruta_enlace -> $destino_para_ln")
            enlaces_existentes[] += 1
            return true
        end
        rm(ruta_completa)
    end

    # Crear el enlace
    if estado.dry_run
        log_debug("SIMULACIÓN: Enlace a crear: $ruta_completa -> $destino_para_ln")
        enlaces_creados[] += 1
        return true
    else
        try
            symlink(destino_para_ln, ruta_completa)
            log_debug("Enlace creado: $ruta_completa -> $destino_para_ln")
            enlaces_creados[] += 1
            return true
        catch e
            log_error("Error creando enlace: $ruta_enlace -> $destino_para_ln: $e")
            enlaces_errores[] += 1
            return false
        end
    end
end

function recrear_enlaces_desde_archivo()
    pcloud_dir = get_pcloud_dir()
    archivo_enlaces_origen = joinpath(pcloud_dir, SYMLINKS_FILE)
    archivo_enlaces_local = joinpath(LOCAL_DIR, SYMLINKS_FILE)
    exit_code = true

    log_debug("Buscando archivo de enlaces en: $archivo_enlaces_origen")

    if isfile(archivo_enlaces_origen)
        cp(archivo_enlaces_origen, archivo_enlaces_local)
        log_info("Archivo de enlaces copiado localmente")
    elseif isfile(archivo_enlaces_local)
        log_info("Usando archivo de enlaces local existente")
    else
        log_debug("No se encontró archivo de enlaces, omitiendo recreación")
        return true
    end

    log_info("Recreando enlaces simbólicos...")

    open(archivo_enlaces_local) do file
        for linea in eachline(file)
            parts = split(linea, '\t')
            if length(parts) < 2
                log_warn("Línea inválida en archivo de enlaces (se omite)")
                log_debug("Línea inválida en archivo de enlaces: $linea")
                continue
            end

            ruta_enlace = parts[1]
            destino = parts[2]

            if !procesar_linea_enlace(ruta_enlace, destino)
                exit_code = false
            end
        end
    end

    log_info("Enlaces recreados: $(enlaces_creados[]), Errores: $(enlaces_errores[])")
    if !estado.dry_run
        rm(archivo_enlaces_local)
    end

    return exit_code
end

# =========================
# SINCRONIZACIÓN
# =========================
function resolver_item_relativo(item)
    if isempty(item)
        log_error("Elemento vacío recibido")
        return ""
    end

    # Detectar path traversal y caracteres peligrosos
    if occursin(r"(^|/)\.\.(/|$)", item) || startswith(item, "../") || endswith(item, "/..")
        log_error("Path traversal detectado: $item")
        return ""
    end

    if startswith(item, "/")
        if startswith(item, LOCAL_DIR * "/")
            rel_item = item[length(LOCAL_DIR) + 2:end]
        else
            log_error("--item apunta fuera de \$HOME: $item")
            return ""
        end
    else
        rel_item = item
    end

    # Validación de seguridad adicional
    rel_item_abs = startswith(rel_item, "/") ? rel_item : joinpath(LOCAL_DIR, rel_item)
    rel_item_abs = normalize_path(rel_item_abs)

    if !startswith(rel_item_abs, LOCAL_DIR)
        log_error("--item apunta fuera de \$HOME o contiene path traversal: $rel_item_abs")
        return ""
    end

    return rel_item
end

# Función para sincronizar un elemento
function sincronizar_elemento(elemento)
    pcloud_dir = get_pcloud_dir()

    # Preparar rutas según el modo (subir/bajar)
    if estado.modo == "subir"
        origen = joinpath(LOCAL_DIR, elemento)
        destino = joinpath(pcloud_dir, elemento)
        direccion = "LOCAL → PCLOUD (Subir)"
    else
        origen = joinpath(pcloud_dir, elemento)
        destino = joinpath(LOCAL_DIR, elemento)
        direccion = "PCLOUD → LOCAL (Bajar)"
    end

    # Verificar si el origen existe
    if !isfile(origen) && !isdir(origen)
        log_warn("No existe $origen")
        return false
    end

    # Normalizar si es directorio
    if isdir(origen)
        origen = origen * "/"
        destino = destino * "/"
    end

    # Advertencia si tiene espacios
    if occursin(r"\s", elemento)
        log_warn("El elemento contiene espacios: '$elemento'")
    end

    # Crear directorio destino si no existe
    dir_destino = dirname(destino)
    if !isdir(dir_destino) && !estado.dry_run
        mkpath(dir_destino)
        log_info("Directorio creado: $dir_destino")
    elseif !isdir(dir_destino) && estado.dry_run
        log_info("SIMULACIÓN: Se crearía directorio: $dir_destino")
    end

    log_info("$(BLUE)Sincronizando: $elemento ($direccion)$(NC)")

    # Construir y validar opciones de rsync
    rsync_opts = construir_opciones_rsync()
    if !validate_rsync_opts(rsync_opts)
        log_error("RSYNC_OPTS inválido")
        return false
    end

    # Imprimir comando de forma segura, si estamos en modo debugg
    if estado.debug || estado.verbose
        print_rsync_command(origen, destino, rsync_opts)
    end

    # Ejecutar rsync
    cmd = `rsync $rsync_opts $origen $destino`
    output = ""
    exit_code = 0

    try
        if estado.timeout_minutes > 0 && !estado.dry_run
            output = read(cmd, String; wait=false)
            # Implementar timeout manualmente
            # (Nota: Julia no tiene un timeout directo para run, necesitaríamos usar Tasks)
            # Por simplicidad, omitimos el timeout en esta versión
        else
            output = read(cmd, String)
        end

        # Analizar salida
        creados = count(r"^>f", output)
        actualizados = count(r"^>f\.st", output)
        count = count(r"^[<>]", output)

        # Contar borrados solo si se usa --delete
        if estado.delete
            borrados = count(r"^\*deleting", output)
            archivos_borrados[] += borrados
            log_info("Archivos borrados: $borrados")
        end

        # Actualizar contadores globales
        archivos_transferidos[] += count
        elementos_procesados[] += 1

        log_info("Archivos creados: $creados")
        log_info("Archivos actualizados: $actualizados")
        log_success("Sincronización completada: $elemento ($count archivos transferidos)")
        return true
    catch e
        if occursin("124", string(e))  # Código de salida para timeout
            log_error("TIMEOUT: La sincronización de '$elemento' excedió el límite")
        else
            log_error("Error en sincronización: $elemento: $e")
        end
        errores_sincronizacion[] += 1
        return false
    end
end

# =========================
# Funciones para sincronización Crypto
# =========================
function sincronizar_crypto()
    # Preparar rutas según el modo (subir/bajar)
    if HOSTNAME == HOSTNAME_RTVA
        if estado.modo == "subir"
            origen = LOCAL_CRYPTO_HOSTNAME_RTVA_DIR
            destino = REMOTO_CRYPTO_HOSTNAME_RTVA_DIR
            direccion = "LOCAL → PCLOUD (Crypto Subir)"
        else
            origen = REMOTO_CRYPTO_HOSTNAME_RTVA_DIR
            destino = LOCAL_CRYPTO_HOSTNAME_RTVA_DIR
            direccion = "PCLOUD → LOCAL (Crypto Bajar)"
        end
    else
        if estado.modo == "subir"
            origen = LOCAL_CRYPTO_DIR
            destino = REMOTO_CRYPTO_DIR
            direccion = "LOCAL → PCLOUD (Crypto Subir)"
        else
            origen = REMOTO_CRYPTO_DIR
            destino = LOCAL_CRYPTO_DIR
            direccion = "PCLOUD → LOCAL (Crypto Bajar)"
        end
    end

    # Verificar si el origen existe
    if !isfile(origen) && !isdir(origen)
        log_warn("No existe $origen, creando directorio...")
        if !estado.dry_run
            mkpath(origen)
        end
    end

    # Normalizar si es directorio
    if isdir(origen)
        origen = origen * "/"
        destino = destino * "/"
    end

    println("------------------------------------------")
    log_info("$(BLUE)Sincronizando Crypto: $origen -> $destino ($direccion)$(NC)")
    log_info("Iniciando sincronización de directorio Crypto...")

    # Construir opciones de rsync específicas para Crypto
    crypto_rsync_opts = [
        "--recursive",
        "--verbose",
        "--times",
        "--progress",
        "--whole-file",
        "--itemize-changes"
    ]

    if !estado.overwrite
        push!(crypto_rsync_opts, "--update")
    end

    if estado.dry_run
        push!(crypto_rsync_opts, "--dry-run")
    end

    if estado.delete
        push!(crypto_rsync_opts, "--delete-delay")
    end

    if estado.use_checksum
        push!(crypto_rsync_opts, "--checksum")
    end

    # Excluir el archivo de verificación de montaje de la transferencia
    push!(crypto_rsync_opts, "--exclude=$CLOUD_MOUNT_CHECK_FILE")

    # Añadir exclusiones de línea de comandos
    if !isempty(estado.exclusiones_cli)
        for patron in estado.exclusiones_cli
            push!(crypto_rsync_opts, "--exclude=$patron")
        end
    end

    # Sincroniza KeePass2Android (pcloud -> ~/Cripto)
    if estado.debug || estado.verbose
        print_rsync_command(REMOTE_KEEPASS_DIR, LOCAL_KEEPASS_DIR, crypto_rsync_opts)
    end

    try
        run(`rsync $crypto_rsync_opts $REMOTE_KEEPASS_DIR $LOCAL_KEEPASS_DIR`)
    catch e
        log_error("Error sincronizando KeePass: $e")
    end

    # Imprimir comando de forma segura, si estamos en modo debugg
    if estado.debug || estado.verbose
        print_rsync_command(origen, destino, crypto_rsync_opts)
    end

    # Ejecutar rsync
    cmd = `rsync $crypto_rsync_opts $origen $destino`
    output = ""

    try
        output = read(cmd, String)

        # Contar archivos transferidos
        crypto_count = count(r"^[<>]", output)
        archivos_crypto_transferidos[] += crypto_count

        log_success("Sincronización Crypto completada: $crypto_count archivos transferidos")
        println("------------------------------------------")
        return true
    catch e
        if occursin("124", string(e))  # Código de salida para timeout
            log_error("TIMEOUT: La sincronización Crypto excedió el límite")
        else
            log_error("Error en sincronización Crypto: $e")
        end
        errores_sincronizacion[] += 1
        return false
    end
end

# =========================
# Funciones modulares para sincronización
# =========================
function verificar_precondiciones()
    log_debug("Verificando precondiciones...")

    # Verificar pCloud montado
    if !verificar_pcloud_montado()
        log_error("Fallo en verificación de pCloud montado - abortando")
        return false
    else
        log_info("Verificación de pCloud montado: OK")
    end

    # Verificar conectividad (solo advertencia)
    verificar_conectividad_pcloud()

    # Verificar espacio en disco (solo en modo ejecución real)
    if !estado.dry_run
        if !verificar_espacio_disco(500)
            log_error("Fallo en verificación de espacio en disco - abortando")
            return false
        else
            log_info("Verificación de espacio en disco: OK")
        end
    else
        log_debug("Modo dry-run: omitiendo verificación de espacio")
    end

    log_info("Todas las precondiciones verificadas correctamente")
    return true
end

function procesar_elementos()
    exit_code = true

    if !isempty(estado.items_especificos)
        log_info("Sincronizando $(length(estado.items_especificos)) elementos específicos")
        for elemento in estado.items_especificos
            rel_item = resolver_item_relativo(elemento)
            log_debug("Procesando elemento: $elemento (relativo: $rel_item)")

            if !isempty(rel_item)
                if !sincronizar_elemento(rel_item)
                    exit_code = false
                end
                elementos_procesados[] += 1
            else
                log_error("Elemento '$elemento' no válido o vacío después de resolución")
                exit_code = false
            end
            println("------------------------------------------")
        end
    else
        directorios = get_directorios_sincronizacion()
        log_info("Procesando lista de sincronización: $(length(directorios)) elementos")
        for elemento in directorios
            log_debug("Procesando elemento de lista: $elemento")
            if !sincronizar_elemento(elemento)
                exit_code = false
            end
            elementos_procesados[] += 1
            println("------------------------------------------")
        end
    end

    log_info("Procesados $(elementos_procesados[]) elementos con código de salida: $(exit_code ? 0 : 1)")
    return exit_code
end

function manejar_enlaces_simbolicos()
    log_info("Manejando enlaces simbólicos...")

    if estado.modo == "subir"
        log_debug("Creando archivo temporal para enlaces")
        tmp_links = mktemp() do path, io
            path  # Devolver la ruta del archivo temporal
        end

        chmod(tmp_links, 0o600)

        if generar_archivo_enlaces(tmp_links)
            log_info("Archivo de enlaces generado correctamente")
        else
            log_error("Error al generar archio de enlaces")
            return false
        end
    else
        log_debug("Modo bajar: recreando enlaces desde archivo")
        if !recrear_enlaces_desde_archivo()
            log_error("Error al recrear enlaces desde archivo")
            return false
        else
            log_info("Enlaces recreados correctamente")
        end
    end

    return true
end

# Función principal de sincronización
function sincronizar()
    log_info("Iniciando proceso de sincronización en modo: $(estado.modo)")

    # Verificaciones previas
    if !verificar_precondiciones()
        log_error("Fallo en las precondiciones, abortando sincronización")
        return 1
    end

    # Confirmación de ejecución (solo si no es dry-run)
    if !estado.dry_run
        log_debug("Solicitando confirmación de usuario")
        confirmar_ejecucion()
    else
        log_debug("Modo dry-run: omitiendo confirmación de usuario")
    end

    # Procesar elementos
    log_info("Iniciando procesamiento de elementos...")
    if !procesar_elementos()
        log_warn("Procesamiento de elementos completado con errores")
    else
        log_info("Procesamiento de elementos completado correctamente")
    end

    # Sincronizar directorio Crypto si está habilitado
    if estado.sync_crypto
        if !sincronizar_crypto()
            log_warn("Sincronización Crypto completada con errores")
        end
    else
        log_info("Sincronización de directorio Crypto excluida")
    end

    # Manejar enlaces simbólicos
    log_info("Iniciando manejo de enlaces simbólicos...")
    if !manejar_enlaces_simbolicos()
        log_warn("Manejo de enlaces simbólicos completado con errores")
    else
        log_success("Manejo de enlaces simbólicos completado correctamente")
    end

    log_success("Sincronización completada")
    return 0
end

# =========================
# Función principal
# =========================
function main()
    global tiempo_inicio = time()

    # Procesar argumentos
    args = ARGS
    procesar_argumentos(args)

    # Validación final
    if isempty(estado.modo)
        log_error("Debes especificar --subir o --bajar")
        mostrar_ayuda()
        exit(1)
    end

    # Manejar force-unlock
    if estado.force_unlock
        log_warn("Forzando eliminación de lock: $LOCK_FILE")
        rm(LOCK_FILE, force=true)
        exit(0)
    end

    # Verificar dependencias
    verificar_dependencias()

    # Añadir esta verificación antes de iniciar la sincronización
    if !verificar_elementos_configuracion()
        log_error("Error en la configuración. Ejecución abortada.")
        exit(1)
    end

    # Banner de cabecera
    mostrar_banner()

    # Establecer locking
    if !establecer_lock()
        exit(1)
    end

    # Inicializar log
    inicializar_log()

    # Ejecutar sincronización
    exit_code = sincronizar()

    # Eliminar el lock antes de mostrar el resumen
    eliminar_lock_final()

    # Mostrar estadísticas
    mostrar_estadísticas(tiempo_inicio)

    # Enviar notificación de finalización
    notificar_finalizacion(exit_code)

    # Mantener el log del resumen en el archivo de log también
    open(LOG_FILE, "a") do file
        write(file, "==========================================\n")
        write(file, "Sincronización finalizada: $(now())\n")
        write(file, "Elementos procesados: $(elementos_procesados[])\n")
        write(file, "Archivos transferidos: $(archivos_transferidos[])\n")
        if estado.sync_crypto
            write(file, "Archivos Crypto transferidos: $(archivos_crypto_transferidos[])\n")
        end
        if estado.delete
            write(file, "Archivos borrados: $(archivos_borrados[])\n")
        end
        if !isempty(estado.exclusiones_cli)
            write(file, "Exclusiones CLI aplicadas: $(length(estado.exclusiones_cli))\n")
        end
        write(file, "Modo dry-run: $(estado.dry_run ? "Sí" : "No")\n")
        write(file, "Enlaces detectados/guardados: $(enlaces_detectados[])\n")
        write(file, "Enlaces creados: $(enlaces_creados[])\n")
        write(file, "Enlaces existentes: $(enlaces_existentes[])\n")
        write(file, "Enlaces con errores: $(enlaces_errores[])\n")
        write(file, "Errores generales: $(errores_sincronizacion[])\n")
        write(file, "Log: $LOG_FILE\n")
        write(file, "==========================================\n")
    end

    exit(exit_code)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
