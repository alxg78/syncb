#?module LoggingModule

#?using ..ConfigModule: Config
#?using Logging
#?using Dates

#?export Logger, setup_logging!, log_info, log_warn, log_error, log_debug, log_success

struct Logger
    config::Config
    verbose::Bool
    log_file::IO
end

function setup_logging!(config::Config, verbose::Bool=false)
    # Configurar logger para consola
    logger = global_logger()
    
    # Crear archivo de log
    log_dir = dirname(config.LOG_FILE)
    if !isdir(log_dir)
        mkpath(log_dir)
    end
    
    log_io = open(config.LOG_FILE, "a")
    
    return Logger(config, verbose, log_io)
end

function log_info(logger::Logger, msg::String)
    timestamp = now()
    formatted_msg = "[$timestamp] INFO: $msg"
    println(logger.log_file, formatted_msg)
    flush(logger.log_file)
    @info msg
end

function log_warn(logger::Logger, msg::String)
    timestamp = now()
    formatted_msg = "[$timestamp] WARN: $msg"
    println(logger.log_file, formatted_msg)
    flush(logger.log_file)
    @warn "$(logger.config.yellow)$(logger.config.warning_icon) $msg$(logger.config.nc)"
end

function log_error(logger::Logger, msg::String)
    timestamp = now()
    formatted_msg = "[$timestamp] ERROR: $msg"
    println(logger.log_file, formatted_msg)
    flush(logger.log_file)
    @error "$(logger.config.red)$(logger.config.cross_mark) $msg$(logger.config.nc)"
end

function log_debug(logger::Logger, msg::String)
    if logger.verbose
        timestamp = now()
        formatted_msg = "[$timestamp] DEBUG: $msg"
        println(logger.log_file, formatted_msg)
        flush(logger.log_file)
        @debug "$(logger.config.magenta)$(logger.config.clock_icon) $msg$(logger.config.nc)"
    end
end

function log_success(logger::Logger, msg::String)
    timestamp = now()
    formatted_msg = "[$timestamp] SUCCESS: $msg"
    println(logger.log_file, formatted_msg)
    flush(logger.log_file)
    @info "$(logger.config.green)$(logger.config.check_mark) $msg$(logger.config.nc)"
end

function close_logger(logger::Logger)
    close(logger.log_file)
end

#?end # module LoggingModule
