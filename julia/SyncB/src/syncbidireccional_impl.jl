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

# ... todas las demás funciones