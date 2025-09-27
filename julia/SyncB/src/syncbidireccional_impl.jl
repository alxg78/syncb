# Aquí van todas las funciones de implementación

function run(app::SyncBidireccional)
    try
        parse_arguments(app)
        mostrar_banner(app)
        
        if !establecer_lock(app)
            return 1
        end
        
        # ... resto de la implementación igual que antes
        return 0
    catch e
        log_error(app.logger, "Error inesperado: $e")
        return 1
    finally
        eliminar_lock(app)
    end
end

function establecer_lock(app::SyncBidireccional)
    # Implementación...
    return true
end

function mostrar_banner(app::SyncBidireccional)
    # Implementación...
end

function eliminar_lock(app::SyncBidireccional)
    lock_file = app.lock_file
    if isfile(lock_file)
        try
            rm(lock_file)
            log_info(app.logger, "Archivo de lock eliminado: $lock_file")
        catch e
            log_error(app.logger, "Error eliminando archivo de lock $lock_file: $e")
        end
    else
        log_debug(app.logger, "No existe archivo de lock para eliminar: $lock_file")
    end
end

function establecer_lock(app::SyncBidireccional)
    lock_file = app.lock_file
    
    if isfile(lock_file)
        try
            # Verificar si el lock es viejo
            file_time = mtime(lock_file)
            current_time = time()
            if current_time - file_time > app.config.lock_timeout
                log_warn(app.logger, "Eliminando lock obsoleto")
                rm(lock_file)
            else
                log_error(app.logger, "Ya existe una ejecución en progreso (lock file: $lock_file)")
                return false
            end
        catch e
            log_warn(app.logger, "Eliminando lock corrupto: $e")
            rm(lock_file)
        end
    end
    
    # Crear nuevo lock
    try
        touch(lock_file)
        log_info(app.logger, "Lock establecido: $lock_file")
        return true
    catch e
        log_error(app.logger, "Error creando lock file: $e")
        return false
    end
end



