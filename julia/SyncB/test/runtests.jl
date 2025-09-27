using SyncB
using Test

@testset "SyncB Tests" begin
    # Test de configuración
    @testset "Config" begin
        config = SyncB.ConfigModule.Config()
        @test config.local_dir isa String
        @test config.hostname_rtva == "feynman.rtva.dnf"
    end
    
    # Test de argumentos
    @testset "Args Parser" begin
        # Test básico de parseo
    end
end