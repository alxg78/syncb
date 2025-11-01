#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    use std::fs;

    #[test]
    fn test_config_loading() {
        let temp_dir = TempDir::new().unwrap();
        let config_path = temp_dir.path().join("config.toml");
        
        fs::write(&config_path, r#"
            [general]
            local_dir = "/home/test"
            pcloud_mount_point = "/home/test/pCloudDrive"
            pcloud_backup_comun = "/home/test/pCloudDrive/Backups/Backup_Comun"
            pcloud_backup_readonly = "/home/test/pCloudDrive/pCloud Backup/test"
            log_file = "/home/test/syncb.log"
            lock_file = "/tmp/syncb_test.lock"
            lock_timeout_seconds = 3600
            default_timeout_minutes = 30

            [general.crypto]
            local_crypto_dir = "/home/test/Crypto"
            remote_crypto_dir = "/home/test/pCloudDrive/Crypto Folder"
            cloud_mount_check_file = "mount.check"
            local_keepass_dir = "/home/test/Crypto/Keepass2Android"
            remote_keepass_dir = "/home/test/pCloudDrive/Applications/Keepass2Android"
            local_crypto_hostname_rtva_dir = "/home/test/Crypto/ficheros_sensibles"
            remote_crypto_hostname_rtva_dir = "/home/test/pCloudDrive/Crypto Folder/ficheros_sensibles"

            [hosts.default]
            sync_items = ["test_file.txt"]
            exclusions = ["*.tmp"]
        "#).unwrap();

        // Test de carga de configuración
        // (Implementar según sea necesario)
    }

    #[test]
    fn test_path_validation() {
        // Test de validación de rutas contra path traversal
        // (Implementar según sea necesario)
    }

    #[tokio::test]
    async fn test_sync_manager_creation() {
        // Test de creación del gestor de sincronización
        // (Implementar según sea necesario)
    }
}