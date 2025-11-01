#module UtilsModule

#using FilePathsBase
#using Dates

#export cleanup_temporales, manejo_temporal_context

function cleanup_temporales(files::Vector{String}, dirs::Vector{String})
    for file in files
        if isfile(file)
            try
                rm(file)
            catch e
                @warn "No se pudo eliminar archivo temporal $file: $e"
            end
        end
    end
    
    for dir in dirs
        if isdir(dir)
            try
                rm(dir; recursive=true)
            catch e
                @warn "No se pudo eliminar directorio temporal $dir: $e"
            end
        end
    end
end

function manejo_temporal_context()
    files = String[]
    dirs = String[]
    
    return (files=files, dirs=dirs)  # Retornar contexto para uso con do-block
end

#end # module UtilsModule
