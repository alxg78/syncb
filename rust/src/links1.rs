use std::fs;
use std::path::{Path, PathBuf};
use std::collections::HashMap;
use anyhow::Result;
use crate::logging::Logger;
use crate::sync::SyncStats;

pub struct SymbolicLinks {
    local_dir: PathBuf,
    symlinks_file: String,
}

impl SymbolicLinks {
    pub fn new(local_dir: PathBuf, symlinks_file: String) -> Self {
        Self {
            local_dir,
            symlinks_file,
        }
    }
    
    pub fn generar_archivo_enlaces(
        &self, 
        items: &[String],
        pcloud_dir: &Path,
        stats: &mut SyncStats,
        logger: &mut Logger
    ) -> Result<()> {
        let archivo_enlaces = tempfile::NamedTempFile::new()?;
        let archivo_path = archivo_enlaces.path();
        
        let mut enlaces = HashMap::new();
        
        for item in items {
            self.procesar_item(item, &mut enlaces, stats, logger)?;
        }
        
        // Escribir enlaces al archivo temporal
        let mut file = fs::File::create(archivo_path)?;
        for (ruta, destino) in &enlaces {
            writeln!(file, "{}\t{}", ruta, destino)?;
        }
        
        stats.enlaces_detectados = enlaces.len() as u32;
        
        // Sincronizar archivo de enlaces a pCloud
        let destino_enlaces = pcloud_dir.join(&self.symlinks_file);
        if let Some(parent) = destino_enlaces.parent() {
            fs::create_dir_all(parent)?;
        }
        
        fs::copy(archivo_path, &destino_enlaces)?;
        
        log_info!(logger, "Enlaces detectados/guardados: {}", enlaces.len());
        log_info!(logger, "Archivo de enlaces sincronizado: {}", destino_enlaces.display());
        
        Ok(())
    }
    
    fn procesar_item(
        &self, 
        item: &str, 
        enlaces: &mut HashMap<String, String>,
        stats: &mut SyncStats,
        logger: &mut Logger
    ) -> Result<()> {
        let ruta_completa = self.local_dir.join(item);
        
        if ruta_completa.is_symlink() {
            self.registrar_enlace(&ruta_completa, item, enlaces, logger)?;
        } else if ruta_completa.is_dir() {
            self.buscar_enlaces_en_directorio(&ruta_completa, enlaces, logger)?;
        }
        
        Ok(())
    }
    
    // ... resto del código de links.rs similar al anterior pero adaptado
}