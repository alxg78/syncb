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
    Para subir: julia sync_bidireccional.jl --subir [opciones]
    Para bajar: julia sync_bidireccional.jl --bajar [opciones]

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

# Cargar Pkg para gestión de paquetes
using Pkg

# Lista de paquetes requeridos
required_packages = ["ArgParse", "JSON", "LoggingExtras", "ProgressMeter"]

# Verificar e instalar paquetes faltantes
for pkg in required_packages
    try
        # Intentar cargar el paquete
        eval(Meta.parse("using $pkg"))
    catch e
        # Si falla, instalarlo
        println("Instalando paquete faltante: $pkg")
        Pkg.add(pkg)
        # Intentar cargarlo nuevamente
        eval(Meta.parse("using $pkg"))
    end
end

# Ahora cargamos los paquetes normalmente
using ArgParse
using JSON
using Logging
using LoggingExtras
using ProgressMeter
using Dates
import Base: @kwdef




# Configuración global
@kwdef mutable struct Config
    PCLOUD_MOUNT_POINT::String = joinpath(homedir(), "pCloudDrive")
    LOCAL_DIR::String = homedir()
    PCLOUD_BACKUP_COMUN::String = joinpath(PCLOUD_MOUNT_POINT, "Backups", "Backup_Comun")
    PCLOUD_BACKUP_READONLY::String = joinpath(PCLOUD_MOUNT_POINT, "pCloud Backup", "feynman.sobremesa.dnf")
    LISTA_POR_DEFECTO_FILE::String = "sync_bidireccional_directorios.ini"
    LISTA_ESPECIFICA_POR_DEFECTO_FILE::String = "sync_bidireccional_directorios_$(gethostname()).ini"
    EXCLUSIONES_FILE::String = "sync_bidireccional_exclusiones.ini"
    SYMLINKS_FILE::String = ".sync_bidireccional_symlinks.meta"
    LOG_FILE::String = joinpath(homedir(), "sync_bidireccional.log")
    LOCK_FILE::String = joinpath(tempdir(), "sync_bidireccional.lock")
    LOCK_TIMEOUT::Int = 3600  # 1 hora en segundos
    HOSTNAME_RTVA::String = "feynman.rtva.dnf"
end

# Estructura principal de la aplicación
@kwdef mutable struct Syncb
    config::Config = Config()
    modo::Union{Nothing, String} = nothing
    dry_run::Bool = false
    delete::Bool = false
    yes::Bool = false
    overwrite::Bool = false
    backup_dir_mode::String = "comun"
    verbose::Bool = false
    use_checksum::Bool = false
    bw_limit::Union{Nothing, Int} = nothing
    timeout_minutes::Int = 30
    items_especificos::Vector{String} = String[]
    exclusiones_cli::Vector{String} = String[]
    lista_sincronizacion::Union{Nothing, String} = nothing
    exclusiones::Union{Nothing, String} = nothing
    elementos_procesados::Int = 0
    errores_sincronizacion::Int = 0
    archivos_transferidos::Int = 0
    enlaces_creados::Int = 0
    enlaces_existentes::Int = 0
    enlaces_errores::Int = 0
    enlaces_detectados::Int = 0
    archivos_borrados::Int = 0
    start_time::Float64 = time()
    hostname::String = gethostname()
    script_dir::String = @__DIR__
    logger::Union{Nothing, AbstractLogger} = ConsoleLogger(stdout, Logging.Info)
end

# Ya no necesitas el constructor Syncb() separado

function setup_logging(app::Syncb)
    # Crear logger con formateo personalizado
    logger = TeeLogger(
        MinLevelLogger(
            FileLogger(app.config.LOG_FILE, append=true),
            Logging.Info
        ),
        ConsoleLogger(stdout, Logging.Debug)
    )
    
    app.logger = logger
    return logger
end

function log_info(app::Syncb, msg)
    @info msg
end

function log_warn(app::Syncb, msg)
    @warn msg
end

function log_error(app::Syncb, msg)
    @error msg
end

function log_debug(app::Syncb, msg)
    @debug msg
end

function parse_arguments(app::Syncb)
    s = ArgParseSettings()
    
    @add_arg_table! s begin
        "--subir"
            action = :store_true
            help = "Sincroniza desde local a pCloud"
        "--bajar"
            action = :store_true
            help = "Sincroniza desde pCloud a local"
        "--delete"
            action = :store_true
            help = "Elimina archivos obsoletos en destino"
        "--dry-run"
            action = :store_true
            help = "Simula sin hacer cambios reales"
        "--item"
            action = :append_arg
            help = "Sincroniza solo el elemento especificado"
        "--exclude"
            action = :append_arg
            help = "Excluye archivos que coincidan con el patrón"
        "--yes"
            action = :store_true
            help = "Ejecuta sin confirmación"
        "--backup-dir"
            action = :store_true
            help = "Usa directorio de backup de solo lectura"
        "--overwrite"
            action = :store_true
            help = "Sobrescribe todos los archivos en destino"
        "--checksum"
            action = :store_true
            help = "Fuerza comparación con checksum"
        "--bwlimit"
            action = :store_arg
            help = "Limita la velocidad de transferencia (KB/s)"
            arg_type = Int
        "--timeout"
            action = :store_arg
            help = "Límite de tiempo por operación (minutos)"
            arg_type = Int
            default = 30
        "--force-unlock"
            action = :store_true
            help = "Fuerza eliminación de lock"
        "--verbose"
            action = :store_true
            help = "Habilita modo verboso"
        "--test"
            action = :store_true
            help = "Ejecuta tests unitarios"
    end
    
    args = parse_args(ARGS, s)
    
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
        exit(0)
    end
    
    if args["test"]
        run_tests(app)
        exit(0)
    end
    
    if (app.modo === nothing && !args["test"] && !args["force-unlock"])
        println(s.help)
        exit(0)
    end
end

function mostrar_estadisticas(app::Syncb)
    tiempo_total = round(time() - app.start_time, digits=2)
    println("\n" * "="^50)
    println("ESTADÍSTICAS DE SINCRONIZACIÓN")
    println("Tiempo total: $tiempo_total segundos")
    println("Elementos procesados: $(app.elementos_procesados)")
    println("Archivos transferidos: $(app.archivos_transferidos)")
    println("Errores de sincronización: $(app.errores_sincronizacion)")
    println("Enlaces creados: $(app.enlaces_creados)")
    println("Enlaces existentes: $(app.enlaces_existentes)")
    println("Errores en enlaces: $(app.enlaces_errores)")
    println("Enlaces detectados: $(app.enlaces_detectados)")
    println("Archivos borrados: $(app.archivos_borrados)")
    println("="^50)
end

function force_unlock(app::Syncb)
    if isfile(app.config.LOCK_FILE)
        rm(app.config.LOCK_FILE)
        log_info(app, "Lock eliminado forzosamente")
    else
        log_info(app, "No existe archivo de lock")
    end
end

function get_pcloud_dir(app::Syncb)
    if app.backup_dir_mode == "readonly"
        return app.config.PCLOUD_BACKUP_READONLY
    else
        return app.config.PCLOUD_BACKUP_COMUN
    end
end

function find_config_files(app::Syncb)
    # Si el hostname es el de RTVA, usar archivo específico
    if app.hostname == app.config.HOSTNAME_RTVA
        lista_especifica = replace(app.config.LISTA_ESPECIFICA_POR_DEFECTO_FILE, "{HOSTNAME}" => app.config.HOSTNAME_RTVA)
        
        # Buscar en directorio del script
        lista_path = joinpath(app.script_dir, lista_especifica)
        if isfile(lista_path)
            app.lista_sincronizacion = lista_path
        else
            # Buscar en directorio actual
            lista_path = joinpath(pwd(), lista_especifica)
            if isfile(lista_path)
                app.lista_sincronizacion = lista_path
            else
                log_error(app, "No se encontró el archivo de lista específico '$lista_especifica'")
                exit(1)
            end
        end
    else
        # Para otros hostnames, usar archivo por defecto
        lista_path = joinpath(app.script_dir, app.config.LISTA_POR_DEFECTO_FILE)
        if isfile(lista_path)
            app.lista_sincronizacion = lista_path
        else
            lista_path = joinpath(pwd(), app.config.LISTA_POR_DEFECTO_FILE)
            if isfile(lista_path)
                app.lista_sincronizacion = lista_path
            end
        end
    end
    
    # Buscar archivo de exclusiones
    exclusiones_path = joinpath(app.script_dir, app.config.EXCLUSIONES_FILE)
    if isfile(exclusiones_path)
        app.exclusiones = exclusiones_path
    else
        exclusiones_path = joinpath(pwd(), app.config.EXCLUSIONES_FILE)
        if isfile(exclusiones_path)
            app.exclusiones = exclusiones_path
        end
    end
end

function verificar_pcloud_montado(app::Syncb)
    pcloud_dir = get_pcloud_dir(app)
    
    # Verificar si el punto de montaje existe
    if !isdir(app.config.PCLOUD_MOUNT_POINT)
        log_error(app, "El punto de montaje de pCloud no existe: $(app.config.PCLOUD_MOUNT_POINT)")
        return false
    end
    
    # Verificar si el directorio está vacío (puede indicar que no está montado)
    if isempty(readdir(app.config.PCLOUD_MOUNT_POINT))
        log_error(app, "El directorio de pCloud está vacío: $(app.config.PCLOUD_MOUNT_POINT)")
        return false
    end
    
    # Verificar si el directorio específico de pCloud existe
    if !isdir(pcloud_dir)
        log_error(app, "El directorio de pCloud no existe: $pcloud_dir")
        return false
    end
    
    # Verificar permisos de escritura (solo si no es dry-run y no es modo backup-dir)
    if !app.dry_run && app.backup_dir_mode == "comun"
        test_file = joinpath(pcloud_dir, ".test_write_$(getpid())")
        try
            touch(test_file)
            rm(test_file)
        catch e
            log_error(app, "No se puede escribir en: $pcloud_dir")
            return false
        end
    end
    
    log_info(app, "Verificación de pCloud: OK - El directorio está montado y accesible")
    return true
end

function mostrar_banner(app::Syncb)
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
    
    if app.delete
        println("BORRADO: ACTIVADO (se eliminarán archivos obsoletos)")
    end
    
    if app.yes
        println("CONFIRMACIÓN: Automática (sin preguntar)")
    end
    
    if app.overwrite
        println("SOBRESCRITURA: ACTIVADA")
    else
        println("MODO: SEGURO (--update activado)")
    end
    
    if !isempty(app.items_especificos)
        println("ELEMENTOS ESPECÍFICOS: $(join(app.items_especificos, ", "))")
    else
        println("LISTA: $(app.lista_sincronizacion)")
    end
    
    println("EXCLUSIONES: $(app.exclusiones)")
    
    if !isempty(app.exclusiones_cli)
        println("EXCLUSIONES CLI ($(length(app.exclusiones_cli)) patrones):")
        for (i, patron) in enumerate(app.exclusiones_cli)
            println("  $i. $patron")
        end
    end
    
    println("=" ^ 50)
end

function confirmar_ejecucion(app::Syncb)
    if app.yes
        log_info(app, "Confirmación automática (--yes): se procede con la sincronización")
        return
    end
    
    print("¿Desea continuar con la sincronización? [s/N]: ")
    respuesta = readline()
    if lowercase(respuesta) ∉ ["s", "si", "sí", "y", "yes"]
        log_info(app, "Operación cancelada por el usuario.")
        exit(0)
    end
end

function establecer_lock(app::Syncb)
    if isfile(app.config.LOCK_FILE)
        # Leer información del lock existente
        try
            lock_info = JSON.parsefile(app.config.LOCK_FILE)
            
            lock_pid = get(lock_info, "pid", 0)
            lock_time = get(lock_info, "timestamp", 0.0)
            current_time = time()
            lock_age = current_time - lock_time
            
            if lock_age > app.config.LOCK_TIMEOUT
                log_warn(app, "Eliminando lock obsoleto (edad: $(round(lock_age))s > timeout: $(app.config.LOCK_TIMEOUT)s)")
                rm(app.config.LOCK_FILE)
            else
                # Verificar si el proceso todavía existe
                try
                    # Intenta enviar una señal 0 al proceso (solo verifica existencia)
                    run(`ps -p $lock_pid`)
                    log_error(app, "Ya hay una ejecución en progreso (PID: $lock_pid)")
                    log_error(app, "Dueño del lock: PID $lock_pid, Iniciado: $(get(lock_info, "start_time", "desconocido"))")
                    return false
                catch e
                    # El proceso ya no existe
                    log_warn(app, "Eliminando lock obsoleto del proceso $lock_pid")
                    rm(app.config.LOCK_FILE)
                end
            end
        catch e
            # El archivo de lock está corrupto o no se puede leer
            log_warn(app, "Eliminando lock corrupto")
            rm(app.config.LOCK_FILE)
        end
    end
    
    # Crear nuevo lock
    lock_info = Dict(
        "pid" => getpid(),
        "timestamp" => time(),
        "start_time" => now(),
        "modo" => app.modo,
        "user" => get(ENV, "USER", "unknown"),
        "hostname" => app.hostname
    )
    
    try
        open(app.config.LOCK_FILE, "w") do f
            JSON.print(f, lock_info)
        end
        log_info(app, "Lock establecido: $(app.config.LOCK_FILE)")
        return true
    catch e
        log_error(app, "No se pudo crear el archivo de lock: $e")
        return false
    end
end

function eliminar_lock(app::Syncb)
    if isfile(app.config.LOCK_FILE)
        try
            lock_info = JSON.parsefile(app.config.LOCK_FILE)
            if get(lock_info, "pid", 0) == getpid()
                rm(app.config.LOCK_FILE)
                log_info(app, "Lock eliminado")
            end
        catch e
            # Si no podemos leer el lock, lo eliminamos de todas formas
            rm(app.config.LOCK_FILE)
            log_info(app, "Lock eliminado (forzado)")
        end
    end
end

function construir_opciones_rsync(app::Syncb)
    opts = [
        "--recursive",
        "--verbose",
        "--times",
        "--progress",
        "--whole-file",
        "--no-links",
        "--itemize-changes"
    ]
    
    if !app.overwrite
        push!(opts, "--update")
    end
    
    if app.dry_run
        push!(opts, "--dry-run")
    end
    
    if app.delete
        push!(opts, "--delete-delay")
    end
    
    if app.use_checksum
        push!(opts, "--checksum")
    end
    
    if app.bw_limit !== nothing
        push!(opts, "--bwlimit=$(app.bw_limit)")
    end
    
    if app.exclusiones !== nothing && isfile(app.exclusiones)
        push!(opts, "--exclude-from=$(app.exclusiones)")
    end
    
    for patron in app.exclusiones_cli
        push!(opts, "--exclude=$patron")
    end
    
    return opts
end

function sincronizar_elemento(app::Syncb, elemento)
    pcloud_dir = get_pcloud_dir(app)
    
    if app.modo == "subir"
        origen = joinpath(app.config.LOCAL_DIR, elemento)
        destino = joinpath(pcloud_dir, elemento)
        direccion = "LOCAL → PCLOUD (Subir)"
    else
        origen = joinpath(pcloud_dir, elemento)
        destino = joinpath(app.config.LOCAL_DIR, elemento)
        direccion = "PCLOUD → LOCAL (Bajar)"
    end
    
    # Verificar si el origen existe
    if !isfile(origen) && !isdir(origen)
        log_warn(app, "No existe $origen")
        return false
    end
    
    # Normalizar si es directorio
    if isdir(origen)
        origen = origen * "/"
        destino = destino * "/"
    end
    
    # Advertencia si tiene espacios
    if occursin(" ", elemento)
        log_warn(app, "El elemento contiene espacios: '$elemento'")
    end
    
    # Crear directorio destino si no existe
    dir_destino = dirname(destino)
    if !isdir(dir_destino) && !app.dry_run
        mkpath(dir_destino)
        log_info(app, "Directorio creado: $dir_destino")
    elseif !isdir(dir_destino) && app.dry_run
        log_info(app, "SIMULACIÓN: Se crearía directorio: $dir_destino")
    end
    
    log_info(app, "Sincronizando: $elemento ($direccion)")
    
    # Construir comando rsync
    opts = construir_opciones_rsync(app)
    cmd = `rsync $opts $origen $destino`
    
    # Ejecutar comando
    try
        log_debug(app, "Ejecutando: $cmd")
        
        if app.dry_run
            # En dry-run, solo mostramos el comando
            result = run(cmd)
            if success(result)
                analizar_salida_rsync(app, result)
                log_info(app, "Sincronización completada: $elemento")
                return true
            else
                log_error(app, "Error en simulación: $elemento")
                return false
            end
        else
            # Ejecución real
            result = run(cmd)
            if success(result)
                analizar_salida_rsync(app, result)
                log_info(app, "Sincronización completada: $elemento")
                return true
            else
                log_error(app, "Error en sincronización: $elemento")
                app.errores_sincronizacion += 1
                return false
            end
        end
    catch e
        log_error(app, "Error ejecutando rsync: $e")
        app.errores_sincronizacion += 1
        return false
    end
end

function analizar_salida_rsync(app::Syncb, result)
    # Esta función analizaría la salida de rsync para obtener estadísticas
    # Implementación simplificada
    app.archivos_transferidos += 1  # Esto debería ser más sofisticado
    app.elementos_procesados += 1
end

function procesar_elementos(app::Syncb)
    exit_code = 0
    
    if !isempty(app.items_especificos)
        log_info(app, "Sincronizando $(length(app.items_especificos)) elementos específicos")
        for elemento in app.items_especificos
            if !sincronizar_elemento(app, elemento)
                exit_code = 1
            end
            println("-" ^ 50)
        end
    else
        # Leer elementos del archivo de lista
        try
            lineas = readlines(app.lista_sincronizacion)
            lineas = filter(line -> !isempty(strip(line)) && !startswith(line, "#"), lineas)
            
            log_info(app, "Procesando lista de sincronización: $(length(lineas)) elementos")
            for linea in lineas
                if !sincronizar_elemento(app, strip(linea))
                    exit_code = 1
                end
                println("-" ^ 50)
            end
        catch e
            log_error(app, "Error leyendo archivo de lista: $e")
            return 1
        end
    end
    
    return exit_code
end

function main()
    app = Syncb()
    setup_logging(app)
    
    try
        # Procesar argumentos
        parse_arguments(app)
        
        # Buscar archivos de configuración
        find_config_files(app)
        
        # Mostrar banner
        mostrar_banner(app)
        
        # Establecer lock
        if !establecer_lock(app)
            exit(1)
        end
        
        # Verificar dependencias
        if success(`which rsync`) == false
            log_error(app, "rsync no está instalado. Instálalo con:")
            log_info(app, "sudo apt install rsync  # Debian/Ubuntu")
            log_info(app, "sudo dnf install rsync  # RedHat/CentOS")
            exit(1)
        end
        
        # Verificar pCloud montado
        if !verificar_pcloud_montado(app)
            exit(1)
        end
        
        # Confirmar ejecución
        if !app.dry_run
            confirmar_ejecucion(app)
        end
        
        # Inicializar log
        log_info(app, "Iniciando proceso de sincronización")
        
        # Procesar elementos
        exit_code = procesar_elementos(app)
        
        # Mostrar estadísticas
        mostrar_estadisticas(app)
        
        return exit_code
    catch e
        log_error(app, "Error inesperado: $e")
        return 1
    finally
        # Eliminar lock
        eliminar_lock(app)
    end
end

# Ejecutar la aplicación
if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end

