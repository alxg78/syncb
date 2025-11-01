use crate::config::AppConfig;
use crate::error::Result;

pub struct CryptoManager {
    config: AppConfig,
}

impl CryptoManager {
    pub fn new(config: AppConfig) -> Self {
        Self { config }
    }

    pub async fn sync_crypto(&self) -> Result<()> {
        log::info!("Iniciando sincronización de directorio Crypto");

        // Verificar que el volumen Crypto está montado
        self.verify_crypto_mounted().await?;

        // Sincronizar directorio principal de Crypto
        self.sync_main_crypto().await?;

        // Sincronizar KeePass2Android
        self.sync_keepass().await?;

        log::info!("Sincronización Crypto completada");
        Ok(())
    }

    async fn verify_crypto_mounted(&self) -> Result<()> {
        let check_file = self.config.general.crypto.remote_crypto_dir
            .join(&self.config.general.crypto.cloud_mount_check_file);

        if !check_file.exists() {
            return Err(crate::error::AppError::Crypto(
                "El volumen Crypto no está montado o el archivo de verificación no existe".to_string()
            ));
        }

        log::info!("Verificación de Crypto montado: OK");
        Ok(())
    }

    async fn sync_main_crypto(&self) -> Result<()> {
        let (source, destination) = if self.config.is_host_rtva() {
            (
                self.config.general.crypto.local_crypto_hostname_rtva_dir.clone(),
                self.config.general.crypto.remote_crypto_hostname_rtva_dir.clone(),
            )
        } else {
            (
                self.config.general.crypto.local_crypto_dir.clone(),
                self.config.general.crypto.remote_crypto_dir.clone(),
            )
        };

        log::info!("Sincronizando Crypto: {:?} -> {:?}", source, destination);

        // Implementar lógica de sincronización específica para Crypto
        // Similar a la sincronización principal pero con opciones específicas

        Ok(())
    }

    async fn sync_keepass(&self) -> Result<()> {
        log::info!("Sincronizando KeePass2Android");

        // Sincronizar desde pCloud -> local para KeePass
        let _source = self.config.general.crypto.remote_keepass_dir.clone();
        let destination = self.config.general.crypto.local_keepass_dir.clone();

        // Crear directorio destino si no existe
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent)?;
        }

        // Implementar sincronización de KeePass
        // Usar rsync con opciones específicas

        Ok(())
    }
}
