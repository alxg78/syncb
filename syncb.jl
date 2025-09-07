#!/usr/bin/env julia
"""
Script de sincronización bidireccional entre directorio local y pCloud

Este script permite sincronizar archivos y directorios entre un directorio local
y pCloud en ambas direcciones (subir y bajar). Incluye funcionalidades como:
- Sincronización selectiva con listas de directorios
- Manejo de enlaces simbólicos
- Modo simulación (dry-run)
- Eliminación de archivos obsoletos
- Límite de ancho de banda
- Sistema de logging y notificaciones
- Bloqueo de ejecución concurrente

Uso:
    Para subir: julia syncb.jl --subir [opciones]
    Para bajar: julia syncb.jl --bajar [opciones]

Opciones disponibles:
    --subir            Sincroniza desde local a pCloud
    --bajar            Sincroniza desde pCloud a local
    --delete           Elimina archivos obsoletos en destino
    --dry-run          Simula sin hacer cambios reales
    --item ELEMENTO    Sincroniza solo el elemento especificado
    --yes              Ejecuta sin confirmación
    --backup-dir       Usa directorio de backup de solo lectura
    --exclude PATRON   Excluye archivos que coincidan con el patrón
    --overwrite        Sobrescribe todos los archivos en destino
    --checksum         Fuerza comparación con checksum
    --bwlimit KB/s     Limita la velocidad de transferencia
    --timeout MINUTOS  Límite de tiempo por operación
    --force-unlock     Fuerza eliminación de lock
    --verbose          Habilita modo verboso
    --test             Ejecuta tests unitarios
    --help             Muestra ayuda
"""

using ArgParse
using Dates
using Logging
using Printf
using FileSystem
using Distributed
using Random
using Statistics
using LinearAlgebra
using Sockets
using UUIDs

# Configuración global
struct Config
    PCLOUD_MOUNT_POINT::String
    LOCAL_DIR::String
    PCLOUD_BACKUP_COMUN::String
    PCLOUD_BACKUP_READONLY::String
    LISTA_POR_DEFECTO_FILE::String
    LISTA_ESPECIFICA_POR_DEFECTO_FILE::String
    EXCLUSIONES_FILE::String
    SYMLINKS_FILE::String
    LOG_FILE::String
    LOCK_FILE::String
    LOCK_TIMEOUT::Int64
    HOSTNAME_RTVA::String
end

function Config()
    home_dir = homedir()
    pcloud_mount = joinpath(home_dir, "pCloudDrive")
    pcloud_comun = joinpath(pcloud_mount, "Backups", "Backup_Comun")
    pcloud_readonly = joinpath(pcloud_mount, "pCloud Backup", "feynman.sobremesa.dnf")
    
    return Config(
        pcloud_mount,
        home_dir,
        pcloud_comun,
        pcloud_readonly,
        "syncb_directorios.ini",
        "syncb_directorios_$(gethostname()).ini",
        "syncb_exclusiones.ini",
        ".syncb_symlinks.meta",
        joinpath(home_dir, "syncb.log"),
        joinpath(tempdir(), "syncb.lock"),
        3600,  # 1 hora en segundos
        "feynman.rtva.dnf"
    )
end

mutable struct SyncState
    config::Config
    modo::String
    dry_run::Bool
    delete::Bool
    yes::Bool
    overwrite::Bool
    backup_dir_mode::String
    verbose::Bool
    use_checksum::Bool
    bw_limit::Union{Int64, Nothing}
    timeout_minutes::Int64
    items_especificos::Vector{String}
    exclusiones_cli::Vector{String}
    lista_sincronizacion::Union{String, Nothing}
    exclusiones::Union{String, Nothing}
    elementos_procesados::Int64
    errores_sincronizacion::Int64
    archivos_transferidos::Int64
    enlaces_creados::Int64
    enlaces_existentes::Int64
    enlaces_errores::Int64
    enlaces_detectados::Int64
    archivos_borrados::Int64
    start_time::Float64
    hostname::String
    script_dir::String
    logger::Union{Logger, Nothing}
end

function SyncState()
    config = Config()
    return SyncState(
        config,
        "",  # modo
        false,  # dry_run
        false,  # delete
        false,  # yes
        false,  # overwrite
        "comun",  # backup_dir_mode
        false,  # verbose
        false,  # use_checksum
        nothing,  # bw_limit
        30,  # timeout_minutes
        [],  # items_especificos
        [],  # exclusiones_cli
        nothing,  # lista_sincronizacion
        nothing,  # exclusiones
        0,  # elementos_procesados
        0,  # errores_sincronizacion
        0,  # archivos_transferidos
        0,  # enlaces_creados
        0,  # enlaces_existentes
        0,  # enlaces_errores
        0,  # enlaces_detectados
        0,  # archivos_borrados
        time(),  # start_time
        gethostname(),  # hostname
        dirname(Base.source_path()),  # script_dir
        nothing  # logger
    )
end

function setup_logging(state::SyncState)
    # Configurar logging
    log_file = open(state.config.LOG_FILE, "a")
    logger = SimpleLogger(log_file, Logging.Debug)
    state.logger = logger
    return logger
end

function log_info(state::SyncState, msg::String)
    println(msg)
    if state.logger !== nothing
        @info msg
    end
end

function log_warn(state::SyncState, msg::String)
    println("WARN: $msg")
    if state.logger !== nothing
        @warn msg
    end
end

function log_error(state::SyncState, msg::String)
    println("ERROR: $msg")
    if state.logger !== nothing
        @error msg
    end
end

function log_debug(state::SyncState, msg::String)
    if state.verbose
        println("DEBUG: $msg")
        if state.logger !== nothing
            @debug msg
        end
    end
end

function log_success(state::SyncState, msg::String)
    println("SUCCESS: $msg")
    if state.logger !== nothing
        @info "SUCCESS: $msg"
    end
end

function parse_arguments(state::SyncState)
    s = ArgParseSettings(description = "Sincronización bidireccional entre directorio local y pCloud",
                         epilog = "Ejemplos:\n" *
                                  "  julia syncb.jl --subir\n" *
                                  "  julia syncb.jl --bajar --dry-run\n" *
                                  "  julia syncb.jl --subir --delete --yes\n" *
                                  "  julia syncb.jl --subir --item documentos/\n" *
                                  "  julia syncb.jl --bajar --item configuracion.ini --item .local/bin --dry-run")

    @add_arg_table! s begin
        "--subir", "-s"
            action = :store_true
            help = "Sincroniza desde local a pCloud"
        "--bajar", "-b"
            action = :store_true
            help = "Sincroniza desde pCloud a local"
        "--delete", "-d"
            action = :store_true
            help = "Elimina archivos obsoletos en destino"
        "--dry-run", "-n"
            action = :store_true
            help = "Simula sin hacer cambios reales"
        "--item", "-i"
            action = :append_arg
            help = "Sincroniza solo el elemento especificado"
        "--exclude", "-e"
            action = :append_arg
            help = "Excluye archivos que coincidan con el patrón"
        "--yes", "-y"
            action = :store_true
            help = "Ejecuta sin confirmación"
        "--backup-dir", "-B"
            action = :store_true
            help = "Usa directorio de backup de solo lectura"
        "--overwrite", "-o"
            action = :store_true
            help = "Sobrescribe todos los archivos en destino"
        "--checksum", "-c"
            action = :store_true
            help = "Fuerza comparación con checksum"
        "--bwlimit", "-l"
            arg_type = Int64
            help = "Limita la velocidad de transferencia (KB/s)"
        "--timeout", "-t"
            arg_type = Int64
            default = 30
            help = "Límite de tiempo por operación (minutos)"
        "--force-unlock", "-f"
            action = :store_true
            help = "Fuerza eliminación de lock"
        "--verbose", "-v"
            action = :store_true
            help = "Habilita modo verboso"
        "--test", "-T"
            action = :store_true
            help = "Ejecuta tests unitarios"
        "--help", "-h"
            action = :help
            help = "Muestra ayuda"
    end

    args = parse_args(ARGS, s)

    if args["subir"]
        state.modo = "subir"
    elseif args["bajar"]
        state.modo = "bajar"
    end

    state.dry_run = args["dry-run"]
    state.delete = args["delete"]
    state.yes = args["yes"]
    state.overwrite = args["overwrite"]
    state.use_checksum = args["checksum"]
    state.bw_limit = args["bwlimit"]
    state.timeout_minutes = args["timeout"]
    state.verbose = args["verbose"]

    if args["item"] !== nothing
        state.items_especificos = args["item"]
    end

    if args["exclude"] !== nothing
        state.exclusiones_cli = args["exclude"]
    end

    if args["backup-dir"]
        state.backup_dir_mode = "readonly"
    end

    if args["force-unlock"]
        force_unlock(state)
        exit(0)
    end

    if args["test"]
        run_tests(state)
        exit(0)
    end

    if state.modo == ""
        log_error(state, "Debes especificar --subir o --bajar")
        exit(1)
    end
end

function force_unlock(state::SyncState)
    if isfile(state.config.LOCK_FILE)
        rm(state.config.LOCK_FILE)
        log_info(state, "Lock eliminado forzosamente")
    else
        log_info(state, "No existe archivo de lock")
    end
end

function get_pcloud_dir(state::SyncState)
    if state.backup_dir_mode == "readonly"
        return state.config.PCLOUD_BACKUP_READONLY
    else
        return state.config.PCLOUD_BACKUP_COMUN
    end
end

function find_config_files(state::SyncState)
    # Si el hostname es el de RTVA, usar archivo específico
    if state.hostname == state.config.HOSTNAME_RTVA
        lista_especifica = replace(state.config.LISTA_ESPECIFICA_POR_DEFECTO_FILE, "{HOSTNAME}" => state.config.HOSTNAME_RTVA)
        lista_path = joinpath(state.script_dir, lista_especifica)
        if isfile(lista_path)
            state.lista_sincronizacion = lista_path
        else
            lista_path = joinpath(pwd(), lista_especifica)
            if isfile(lista_path)
                state.lista_sincronizacion = lista_path
            else
                log_error(state, "No se encontró el archivo de lista específico '$lista_especifica'")
                exit(1)
            end
        end
    else
        # Para otros hostnames, usar archivo por defecto
        lista_path = joinpath(state.script_dir, state.config.LISTA_POR_DEFECTO_FILE)
        if isfile(lista_path)
            state.lista_sincronizacion = lista_path
        else
            lista_path = joinpath(pwd(), state.config.LISTA_POR_DEFECTO_FILE)
            if isfile(lista_path)
                state.lista_sincronizacion = lista_path
            end
        end
    end

    # Buscar archivo de exclusiones
    exclusiones_path = joinpath(state.script_dir, state.config.EXCLUSIONES_FILE)
    if isfile(exclusiones_path)
        state.exclusiones = exclusiones_path
    else
        exclusiones_path = joinpath(pwd(), state.config.EXCLUSIONES_FILE)
        if isfile(exclusiones_path)
            state.exclusiones = exclusiones_path
        end
    end
end

function verificar_pcloud_montado(state::SyncState)
    pcloud_dir = get_pcloud_dir(state)
    
    # Verificar si el punto de montaje existe
    if !isdir(state.config.PCLOUD_MOUNT_POINT)
        log_error(state, "El punto de montaje de pCloud no existe: $(state.config.PCLOUD_MOUNT_POINT)")
        return false
    end
    
    # Verificar si el directorio está vacío (puede indicar que no está montado)
    try
        if isempty(readdir(state.config.PCLOUD_MOUNT_POINT))
            log_error(state, "El directorio de pCloud está vacío: $(state.config.PCLOUD_MOUNT_POINT)")
            return false
        end
    catch e
        log_error(state, "Error accediendo al directorio: $(state.config.PCLOUD_MOUNT_POINT) - $e")
        return false
    end
    
    # Verificar si el directorio específico de pCloud existe
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
            log_error(state, "No se puede escribir en: $pcloud_dir - $e")
            return false
        end
    end
    
    log_info(state, "Verificación de pCloud: OK - El directorio está montado y accesible")
    return true
end

function mostrar_banner(state::SyncState)
    pcloud_dir = get_pcloud_dir(state)
    
    println("=" ^ 50)
    if state.modo == "subir"
        println("MODO: SUBIR (Local → pCloud)")
        println("ORIGEN: $(state.config.LOCAL_DIR)")
        println("DESTINO: $pcloud_dir")
    else
        println("MODO: BAJAR (pCloud → Local)")
        println("ORIGEN: $pcloud_dir")
        println("DESTINO: $(state.config.LOCAL_DIR)")
    end
    
    if state.backup_dir_mode == "readonly"
        println("DIRECTORIO: Backup de solo lectura (pCloud Backup)")
    else
        println("DIRECTORIO: Backup común (Backup_Comun)")
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
    
    if !isempty(state.items_especificos)
        println("ELEMENTOS ESPECÍFICOS: $(join(state.items_especificos, ", "))")
    else
        println("LISTA: $(state.lista_sincronizacion)")
    end
    
    println("EXCLUSIONES: $(state.exclusiones)")
    
    if !isempty(state.exclusiones_cli)
        println("EXCLUSIONES CLI ($(length(state.exclusiones_cli)) patrones):")
        for (i, patron) in enumerate(state.exclusiones_cli)
            println("  $i. $patron")
        end
    end
    println("=" ^ 50)
end

function confirmar_ejecucion(state::SyncState)
    if state.yes
        log_info(state, "Confirmación automática (--yes): se procede con la sincronización")
        return
    end
    
    print("¿Desea continuar con la sincronización? [s/N]: ")
    respuesta = readline()
    if lowercase(respuesta) ∉ ["s", "si", "sí", "y", "yes"]
        log_info(state, "Operación cancelada por el usuario.")
        exit(0)
    end
end

function establecer_lock(state::SyncState)
    if isfile(state.config.LOCK_FILE)
        try
            lock_info = JSON.parsefile(state.config.LOCK_FILE)
            lock_pid = lock_info["pid"]
            lock_time = lock_info["timestamp"]
            current_time = time()
            lock_age = current_time - lock_time
            
            if lock_age > state.config.LOCK_TIMEOUT
                log_warn(state, "Eliminando lock obsoleto (edad: $(lock_age)s > timeout: $(state.config.LOCK_TIMEOUT)s)")
                rm(state.config.LOCK_FILE)
            else
                # Verificar si el proceso todavía existe
                try
                    run(`ps -p $lock_pid`)
                    log_error(state, "Ya hay una ejecución en progreso (PID: $lock_pid)")
                    log_error(state, "Dueño del lock: PID $lock_pid, Iniciado: $(lock_info["start_time"])")
                    return false
                catch e
                    # El proceso ya no existe
                    log_warn(state, "Eliminando lock obsoleto del proceso $lock_pid")
                    rm(state.config.LOCK_FILE)
                end
            end
        catch e
            # El archivo de lock está corrupto o no se puede leer
            log_warn(state, "Eliminando lock corrupto")
            rm(state.config.LOCK_FILE)
        end
    end
    
    # Crear nuevo lock
    lock_info = Dict(
        "pid" => getpid(),
        "timestamp" => time(),
        "start_time" => now(),
        "modo" => state.modo,
        "user" => ENV["USER"],
        "hostname" => state.hostname
    )
    
    try
        open(state.config.LOCK_FILE, "w") do f
            JSON.print(f, lock_info)
        end
        log_info(state, "Lock establecido: $(state.config.LOCK_FILE)")
        return true
    catch e
        log_error(state, "No se pudo crear el archivo de lock: $e")
        return false
    end
end

function eliminar_lock(state::SyncState)
    if isfile(state.config.LOCK_FILE)
        try
            lock_info = JSON.parsefile(state.config.LOCK_FILE)
            if lock_info["pid"] == getpid()
                rm(state.config.LOCK_FILE)
                log_info(state, "Lock eliminado")
            end
        catch e
            # Si no podemos leer el lock, lo eliminamos de todas formas
            rm(state.config.LOCK_FILE)
            log_info(state, "Lock eliminado (forzado)")
        end
    end
end

function construir_opciones_rsync(state::SyncState)
    opts = [
        "--recursive",
        "--verbose",
        "--times",
        "--progress",
        "--whole-file",
        "--no-links",
        "--itemize-changes"
    ]
    
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
    
    if state.bw_limit !== nothing
        push!(opts, "--bwlimit=$(state.bw_limit)")
    end
    
    if state.exclusiones !== nothing && isfile(state.exclusiones)
        push!(opts, "--exclude-from=$(state.exclusiones)")
    end
    
    for patron in state.exclusiones_cli
        push!(opts, "--exclude=$patron")
    end
    
    return opts
end

function sincronizar_elemento(state::SyncState, elemento::String)
    pcloud_dir = get_pcloud_dir(state)
    
    if state.modo == "subir"
        origen = joinpath(state.config.LOCAL_DIR, elemento)
        destino = joinpath(pcloud_dir, elemento)
        direccion = "LOCAL → PCLOUD (Subir)"
    else
        origen = joinpath(pcloud_dir, elemento)
        destino = joinpath(state.config.LOCAL_DIR, elemento)
        direccion = "PCLOUD → LOCAL (Bajar)"
    end
    
    # Verificar si el origen existe
    if !isfile(origen) && !isdir(origen)
        log_warn(state, "No existe $origen")
        return false
    end
    
    # Normalizar si es directorio
    if isdir(origen)
        origen = string(origen, "/")
        destino = string(destino, "/")
    end
    
    # Advertencia si tiene espacios
    if occursin(" ", elemento)
        log_warn(state, "El elemento contiene espacios: '$elemento'")
    end
    
    # Crear directorio destino si no existe
    dir_destino = dirname(destino)
    if !isdir(dir_destino) && !state.dry_run
        mkpath(dir_destino)
        log_info(state, "Directorio creado: $dir_destino")
    elseif !isdir(dir_destino) && state.dry_run
        log_info(state, "SIMULACIÓN: Se crearía directorio: $dir_destino")
    end
    
    log_info(state, "Sincronizando: $elemento ($direccion)")
    
    # Construir comando rsync
    opts = construir_opciones_rsync(state)
    cmd = `rsync $opts $origen $destino`
    
    # Ejecutar comando
    try
        log_debug(state, "Ejecutando: $cmd")
        
        if state.dry_run
            # En dry-run, solo mostramos el comando
            result = run(cmd)
            if result.exitcode == 0
                # Analizar salida (simplificado)
                state.archivos_transferidos += 1
                log_success(state, "Sincronización completada: $elemento")
                return true
            else
                log_error(state, "Error en simulación: $elemento")
                return false
            end
        else
            # Ejecución real
            result = run(cmd)
            if result.exitcode == 0
                # Analizar salida (simplificado)
                state.archivos_transferidos += 1
                log_success(state, "Sincronización completada: $elemento")
                return true
            else
                log_error(state, "Error en sincronización: $elemento")
                state.errores_sincronizacion += 1
                return false
            end
        end
    catch e
        log_error(state, "Error ejecutando rsync: $e")
        state.errores_sincronizacion += 1
        return false
    end
end

function procesar_elementos(state::SyncState)
    exit_code = 0
    
    if !isempty(state.items_especificos)
        log_info(state, "Sincronizando $(length(state.items_especificos)) elementos específicos")
        for elemento in state.items_especificos
            if !sincronizar_elemento(state, elemento)
                exit_code = 1
            end
            println("-" ^ 50)
        end
    else
        # Leer elementos del archivo de lista
        try
            elementos = readlines(state.lista_sincronizacion)
            elementos = filter(line -> !isempty(strip(line)) && !startswith(strip(line), "#"), elementos)
            
            log_info(state, "Procesando lista de sincronización: $(length(elementos)) elementos")
            for elemento in elementos
                if !sincronizar_elemento(state, elemento)
                    exit_code = 1
                end
                println("-" ^ 50)
            end
        catch e
            log_error(state, "Error leyendo archivo de lista: $e")
            return 1
        end
    end
    
    return exit_code
end

function manejar_enlaces_simbolicos(state::SyncState)
    if state.modo == "subir"
        return generar_archivo_enlaces(state)
    else
        return recrear_enlaces_desde_archivo(state)
    end
end

function generar_archivo_enlaces(state::SyncState)
    pcloud_dir = get_pcloud_dir(state)
    archivo_enlaces = tempname()
    
    try
        log_info(state, "Generando archivo de enlaces simbólicos...")
        
        elementos = isempty(state.items_especificos) ? leer_elementos_lista(state) : state.items_especificos
        
        open(archivo_enlaces, "w") do f
            for elemento in elementos
                ruta_completa = joinpath(state.config.LOCAL_DIR, elemento)
                
                if islink(ruta_completa)
                    registrar_enlace(state, ruta_completa, f)
                elseif isdir(ruta_completa)
                    buscar_enlaces_en_directorio(state, ruta_completa, f)
                end
            end
        end
        
        # Sincronizar archivo de enlaces a pCloud
        if filesize(archivo_enlaces) > 0
            log_info(state, "Sincronizando archivo de enlaces...")
            opts = construir_opciones_rsync(state)
            cmd = `rsync $opts $archivo_enlaces $(joinpath(pcloud_dir, state.config.SYMLINKS_FILE))`
            
            result = run(cmd)
            if result.exitcode == 0
                log_info(state, "Enlaces detectados/guardados en meta: $(state.enlaces_detectados)")
                log_info(state, "Archivo de enlaces sincronizado")
            else
                log_error(state, "Error sincronizando archivo de enlaces")
                return false
            end
        else
            log_info(state, "No se encontraron enlaces simbólicos para registrar")
        end
        
        return true
    catch e
        log_error(state, "Error generando archivo de enlaces: $e")
        return false
    finally
        # Limpiar archivo temporal
        if isfile(archivo_enlaces)
            rm(archivo_enlaces)
        end
    end
end

function leer_elementos_lista(state::SyncState)
    elementos = []
    try
        open(state.lista_sincronizacion, "r") do f
            for linea in eachline(f)
                linea = strip(linea)
                if !isempty(linea) && !startswith(linea, "#")
                    push!(elementos, linea)
                end
            end
        end
    catch e
        log_error(state, "Error leyendo archivo de lista: $e")
    end
    return elementos
end

function registrar_enlace(state::SyncState, enlace::String, archivo::IO)
    try
        # Ruta relativa del enlace
        ruta_relativa = relpath(enlace, state.config.LOCAL_DIR)
        
        # Destino del enlace
        destino = readlink(enlace)
        
        # Normalización del destino
        if startswith(destino, state.config.LOCAL_DIR)
            destino = replace(destino, state.config.LOCAL_DIR => "/home/\$USERNAME")
        elseif startswith(destino, "/home/")
            # Reemplazar nombre de usuario específico por variable
            partes = split(destino, "/")
            if length(partes) >= 3
                destino = join(["/home/\$USERNAME"; partes[4:end]], "/")
            end
        end
        
        # Escribir en archivo
        write(archivo, "$ruta_relativa\t$destino\n")
        state.enlaces_detectados += 1
        log_info(state, "Registrado enlace: $ruta_relativa -> $destino")
    catch e
        log_error(state, "Error registrando enlace $enlace: $e")
    end
end

function buscar_enlaces_en_directorio(state::SyncState, directorio::String, archivo::IO)
    try
        for (root, dirs, files) in walkdir(directorio)
            for name in vcat(files, dirs)
                ruta_completa = joinpath(root, name)
                if islink(ruta_completa)
                    registrar_enlace(state, ruta_completa, archivo)
                end
            end
        end
    catch e
        log_error(state, "Error buscando enlaces en $directorio: $e")
    end
end

function recrear_enlaces_desde_archivo(state::SyncState)
    pcloud_dir = get_pcloud_dir(state)
    archivo_enlaces_origen = joinpath(pcloud_dir, state.config.SYMLINKS_FILE)
    archivo_enlaces_local = joinpath(state.config.LOCAL_DIR, state.config.SYMLINKS_FILE)
    
    log_info(state, "Buscando archivo de enlaces...")
    
    # Copiar archivo localmente
    if isfile(archivo_enlaces_origen)
        cp(archivo_enlaces_origen, archivo_enlaces_local)
        log_info(state, "Archivo de enlaces copiado localmente")
    elseif isfile(archivo_enlaces_local)
        log_info(state, "Usando archivo de enlaces local existente")
    else
        log_info(state, "No se encontró archivo de enlaces, omitiendo recreación")
        return true
    end
    
    log_info(state, "Recreando enlaces simbólicos...")
    exit_code = 0
    
    try
        open(archivo_enlaces_local, "r") do f
            for linea in eachline(f)
                linea = strip(linea)
                if isempty(linea) || !contains(linea, '\t')
                    continue
                end
                
                partes = split(linea, '\t')
                ruta_enlace = partes[1]
                destino = partes[2]
                
                if !procesar_linea_enlace(state, ruta_enlace, destino)
                    exit_code = 1
                end
            end
        end
        
        log_info(state, "Enlaces recreados: $(state.enlaces_creados), Errores: $(state.enlaces_errores)")
        return exit_code == 0
    catch e
        log_error(state, "Error recreando enlaces: $e")
        return false
    finally
        # Limpiar archivo temporal
        if !state.dry_run && isfile(archivo_enlaces_local)
            rm(archivo_enlaces_local)
        end
    end
end

function procesar_linea_enlace(state::SyncState, ruta_enlace::String, destino::String)
    try
        ruta_completa = joinpath(state.config.LOCAL_DIR, ruta_enlace)
        dir_padre = dirname(ruta_completa)
        
        # Normalizar destino
        destino = replace(destino, "\$USERNAME" => ENV["USER"])
        if startswith(destino, "/home/\$USERNAME")
            destino = replace(destino, "/home/\$USERNAME" => state.config.LOCAL_DIR)
        end
        
        # Crear directorio padre si no existe
        if !isdir(dir_padre) && !state.dry_run
            mkpath(dir_padre)
        end
        
        # Si ya existe y apunta a lo mismo
        if islink(ruta_completa)
            destino_actual = readlink(ruta_completa)
            if destino_actual == destino
                log_info(state, "Enlace ya existe y es correcto: $ruta_enlace -> $destino")
                state.enlaces_existentes += 1
                return true
            end
            # Eliminar enlace existente incorrecto
            if !state.dry_run
                rm(ruta_completa)
            end
        end
        
        # Crear el enlace
        if state.dry_run
            log_info(state, "SIMULACIÓN: ln -sfn '$destino' '$ruta_completa'")
            state.enlaces_creados += 1
        else
            symlink(destino, ruta_completa)
            log_info(state, "Creado enlace: $ruta_enlace -> $destino")
            state.enlaces_creados += 1
        end
        
        return true
    catch e
        log_error(state, "Error creando enlace $ruta_enlace -> $destino: $e")
        state.enlaces_errores += 1
        return false
    end
end

function mostrar_estadisticas(state::SyncState)
    tiempo_total = time() - state.start_time
    horas = floor(tiempo_total / 3600)
    minutos = floor((tiempo_total % 3600) / 60)
    segundos = round(tiempo_total % 60)
    
    println()
    println("=" ^ 50)
    println("RESUMEN DE SINCRONIZACIÓN")
    println("=" ^ 50)
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
        println("Tiempo total: $(Int(horas))h $(Int(minutos))m $(Int(segundos))s")
    elseif tiempo_total >= 60
        println("Tiempo total: $(Int(minutos))m $(Int(segundos))s")
    else
        println("Tiempo total: $(Int(segundos))s")
    end
    
    if tiempo_total > 0
        velocidad_promedio = state.archivos_transferidos / tiempo_total
        println("Velocidad promedio: $(round(velocidad_promedio, digits=2)) archivos/segundo")
    end
    
    println("Modo: $(state.dry_run ? "SIMULACIÓN" : "EJECUCIÓN REAL")")
    println("=" ^ 50)
end

function run_tests(state::SyncState)
    println("Ejecutando tests unitarios...")
    tests_pasados = 0
    tests_fallados = 0
    
    # Test 1: get_pcloud_dir
    println("Test 1: get_pcloud_dir")
    state.backup_dir_mode = "comun"
    pcloud_dir_comun = get_pcloud_dir(state)
    state.backup_dir_mode = "readonly"
    pcloud_dir_readonly = get_pcloud_dir(state)
    
    if (pcloud_dir_comun == state.config.PCLOUD_BACKUP_COMUN && 
        pcloud_dir_readonly == state.config.PCLOUD_BACKUP_READONLY)
        tests_pasados += 1
        println("PASS: get_pcloud_dir")
    else
        tests_fallados += 1
        println("FAIL: get_pcloud_dir")
    end
    
    # Resumen de tests
    println()
    println("=" ^ 50)
    println("RESUMEN DE TESTS")
    println("=" ^ 50)
    println("Tests pasados: $tests_pasados")
    println("Tests fallados: $tests_fallados")
    println("Total tests: $(tests_pasados + tests_fallados)")
    
    return tests_fallados == 0
end

function main()
    state = SyncState()
    try
        # Procesar argumentos
        parse_arguments(state)
        
        # Buscar archivos de configuración
        find_config_files(state)
        
        # Mostrar banner
        mostrar_banner(state)
        
        # Establecer lock
        if !establecer_lock(state)
            exit(1)
        end
        
        # Verificar dependencias
        if success(`which rsync`) == false
            log_error(state, "rsync no está instalado. Instálalo con:")
            log_info(state, "sudo apt install rsync  # Debian/Ubuntu")
            log_info(state, "sudo dnf install rsync  # RedHat/CentOS")
            exit(1)
        end
        
        # Verificar pCloud montado
        if !verificar_pcloud_montado(state)
            exit(1)
        end
        
        # Confirmar ejecución
        if !state.dry_run
            confirmar_ejecucion(state)
        end
        
        # Inicializar logging
        setup_logging(state)
        log_info(state, "Iniciando proceso de sincronización")
        
        # Procesar elementos
        exit_code = procesar_elementos(state)
        
        # Manejar enlaces simbólicos
        if !manejar_enlaces_simbolicos(state)
            exit_code = 1
        end
        
        # Mostrar estadísticas
        mostrar_estadisticas(state)
        
        return exit_code
    catch e
        log_error(state, "Error inesperado: $e")
        return 1
    finally
        # Eliminar lock
        eliminar_lock(state)
        
        # Registrar en log
        open(state.config.LOG_FILE, "a") do f
            write(f, "=" ^ 50 * "\n")
            write(f, "Sincronización finalizada: $(now())\n")
            write(f, "Elementos procesados: $(state.elementos_procesados)\n")
            write(f, "Archivos transferidos: $(state.archivos_transferidos)\n")
            if state.delete
                write(f, "Archivos borrados: $(state.archivos_borrados)\n")
            end
            if !isempty(state.exclusiones_cli)
                write(f, "Exclusiones CLI aplicadas: $(length(state.exclusiones_cli))\n")
            end
            write(f, "Modo dry-run: $(state.dry_run ? "Sí" : "No")\n")
            write(f, "Enlaces detectados/guardados: $(state.enlaces_detectados)\n")
            write(f, "Enlaces creados: $(state.enlaces_creados)\n")
            write(f, "Enlaces existentes: $(state.enlaces_existentes)\n")
            write(f, "Enlaces con errores: $(state.enlaces_errores)\n")
            write(f, "Errores generales: $(state.errores_sincronizacion)\n")
            write(f, "Log: $(state.config.LOG_FILE)\n")
            write(f, "=" ^ 50 * "\n")
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
