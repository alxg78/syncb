using Test
using SyncB

@testset "Funciones de utilidad" begin
    @test SyncB.expanduser("~/test") == joinpath(homedir(), "test")
    @test SyncB.get_hostname() isa String
    @test SyncB.get_script_dir() isa String
end

@testset "Configuración" begin
    config = SyncB.load_config()
    @test config isa SyncB.SyncConfig
    @test config.local_dir isa String
    @test !isempty(config.exclusions)
end

@testset "Normalización de rutas" begin
    ctx = nothing  # Mock context para pruebas
    # Tests de normalización...
end

@testset "Argumentos de línea de comandos" begin
    # Tests de parsing...
end