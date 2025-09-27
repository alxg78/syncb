
using FilePathsBase
using Glob

export SymbLinksManager, generar_archivo_enlaces, recrear_enlaces_desde_archivo

struct SymbLinksManager
    config::Config
    logger::Logger
    enlaces_detectados::Int
    enlaces_creados::Int
    enlaces_existentes::Int
    enlaces_errores::Int
end

function SymbLinksManager(config::Config, logger::Logger)
    return SymbLinksManager(config, logger, 0, 0, 0, 0)
end

function generar_archivo_enlaces(manager::SymbLinksManager, elementos::Vector{String}, dry_run::Bool)
    archivo_enlaces = tempname() * ".meta"
    
    try
        log_info(manager.logger, "Generando archivo de enlaces simbólicos...")
        
        open(archivo_enlaces, "w") do file
            for elemento in elementos
                ruta_completa = manager.config.LOCAL_DIR / elemento
                if islink(ruta_completa)
                    registrar_enlace(manager, ruta_completa, file)
                elseif isdir(ruta_completa)
                    buscar_enlaces_en_directorio(manager, ruta_completa, file)
                end
            end
        end
        
        if filesize(archivo_enlaces) > 0
            if !dry_run
                # Sincronizar archivo de enlaces
                pcloud_dir = get_pcloud_dir(manager.config, "comun")
                destino = pcloud_dir / manager.config.symlinks_file
                cp(archivo_enlaces, destino; force=true)
                log_info(manager.logger, "Archivo de enlaces sincronizado")
            end
            log_info(manager.logger, "Enlaces detectados/guardados en meta: $(manager.enlaces_detectados)")
        else
            log_info(manager.logger, "No se encontraron enlaces simbólicos para registrar")
        end
        
        return true
    catch e
        log_error(manager.logger, "Error generando archivo de enlaces: $e")
        return false
    finally
        if isfile(archivo_enlaces)
            rm(archivo_enlaces)
        end
    end
end

#function registrar_enlace(manager::SymbLinksManager, enlace::String, file::IO)
function registrar_enlace(manager::SymbLinksManager, enlace::AbstractPath, file::IO)
#function registrar_enlace(manager::SymbLinksManager, enlace::Path, file::IO)
    try
        ruta_relativa = relative(enlace, manager.config.LOCAL_DIR)
        destino = readlink(enlace)
        
        # Normalización del destino
        if startswith(destino, string(manager.config.LOCAL_DIR))
            destino = replace(destino, string(manager.config.LOCAL_DIR) => "/home/\$USERNAME")
        elseif startswith(destino, "/home/")
            partes = split(destino, "/")
            if length(partes) >= 3
                destino = "/home/\$USERNAME/" * join(partes[4:end], "/")
            end
        end
        
        write(file, "$ruta_relativa\t$destino\n")
        manager.enlaces_detectados += 1
        log_debug(manager.logger, "Registrado enlace: $ruta_relativa -> $destino")
    catch e
        log_error(manager.logger, "Error registrando enlace $enlace: $e")
    end
end

function buscar_enlaces_en_directorio(manager::SymbLinksManager, directorio::AbstractPath, file::IO)
#function buscar_enlaces_en_directorio(manager::SymbLinksManager, directorio::Path, file::IO)
    try
        for (root, dirs, files) in walkdir(directorio)
            for name in vcat(dirs, files)
                ruta_completa = Path(root) / name
                if islink(ruta_completa)
                    registrar_enlace(manager, ruta_completa, file)
                end
            end
        end
    catch e
        log_error(manager.logger, "Error buscando enlaces en $directorio: $e")
    end
end

function recrear_enlaces_desde_archivo(manager::SymbLinksManager, dry_run::Bool)
    pcloud_dir = get_pcloud_dir(manager.config, "comun")
    archivo_enlaces_origen = pcloud_dir / manager.config.symlinks_file
    
    if !isfile(archivo_enlaces_origen)
        log_info(manager.logger, "No se encontró archivo de enlaces, omitiendo recreación")
        return true
    end
    
    archivo_enlaces_local = manager.config.LOCAL_DIR / manager.config.symlinks_file
    cp(archivo_enlaces_origen, archivo_enlaces_local; force=true)
    
    log_info(manager.logger, "Recreando enlaces simbólicos...")
    
    try
        open(archivo_enlaces_local, "r") do file
            for linea in eachline(file)
                linea = strip(linea)
                if isempty(linea) || !contains(linea, '\t')
                    continue
                end
                
                partes = split(linea, '\t', limit=2)
                if length(partes) == 2
                    ruta_enlace, destino = partes
                    procesar_linea_enlace(manager, ruta_enlace, destino, dry_run)
                end
            end
        end
        
        log_info(manager.logger, "Enlaces recreados: $(manager.enlaces_creados), Errores: $(manager.enlaces_errores)")
        return manager.enlaces_errores == 0
    catch e
        log_error(manager.logger, "Error recreando enlaces: $e")
        return false
    finally
        if isfile(archivo_enlaces_local)
            rm(archivo_enlaces_local)
        end
    end
end

function procesar_linea_enlace(manager::SymbLinksManager, ruta_enlace::String, destino::String, dry_run::Bool)
    try
        ruta_completa = manager.config.LOCAL_DIR / ruta_enlace
        dir_padre = parent(ruta_completa)
        
        # Normalizar destino
        destino = replace(destino, "\$USERNAME" => get(ENV, "USER", "user"))
        if startswith(destino, "/home/\$USERNAME")
            destino = replace(destino, "/home/\$USERNAME" => string(manager.config.LOCAL_DIR))
        end
        
        # Crear directorio padre si no existe
        if !isdir(dir_padre) && !dry_run
            mkpath(dir_padre)
        end
        
        # Si ya existe y apunta a lo mismo
        if islink(ruta_completa)
            destino_actual = readlink(ruta_completa)
            if destino_actual == destino
                log_debug(manager.logger, "Enlace ya existe y es correcto: $ruta_enlace -> $destino")
                manager.enlaces_existentes += 1
                return true
            end
            # Eliminar enlace existente incorrecto
            if !dry_run
                rm(ruta_completa)
            end
        end
        
        # Crear el enlace
        if dry_run
            log_debug(manager.logger, "SIMULACIÓN: ln -sfn '$destino' '$ruta_completa'")
            manager.enlaces_creados += 1
        else
            symlink(destino, ruta_completa)
            log_debug(manager.logger, "Creado enlace: $ruta_enlace -> $destino")
            manager.enlaces_creados += 1
        end
        
        return true
    catch e
        log_error(manager.logger, "Error creando enlace $ruta_enlace -> $destino: $e")
        manager.enlaces_errores += 1
        return false
    end
end

function get_pcloud_dir(config::Config, backup_dir_mode::String)
    if backup_dir_mode == "readonly"
        return config.PCLOUD_BACKUP_READONLY
    else
        return config.PCLOUD_BACKUP_COMUN
    end
end

