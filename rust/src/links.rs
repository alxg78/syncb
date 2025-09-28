
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


=======================================================================================================
EL DE ARRIBA ES EL CODIGO NUEVO PERO ESTA IMCONPLETO

EL DE ABAJO ES EL BIEJJO HAY UNA PARTE QUE HAY QUE SUBIR ARRIBA, VAYA COMPLETAR EL DE ARRIBA
=======================================================================================================
use std::fs;
use std::path::{Path, PathBuf};
use std::collections::HashMap;
use anyhow::Result;
use crate::logging::Logger;

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
        sync_list_path: &Path,
        pcloud_dir: &Path,
        logger: &mut Logger
    ) -> Result<()> {
        let archivo_enlaces = tempfile::NamedTempFile::new()?;
        let archivo_path = archivo_enlaces.path();
        
        let mut enlaces = HashMap::new();
        
        if !items.is_empty() {
            // Procesar items específicos
            for item in items {
                self.procesar_item(&item, &mut enlaces, logger)?;
            }
        } else {
            // Procesar desde archivo de lista
            let contenido = fs::read_to_string(sync_list_path)?;
            for linea in contenido.lines() {
                let linea = linea.trim();
                if linea.is_empty() || linea.starts_with('#') {
                    continue;
                }
                self.procesar_item(linea, &mut enlaces, logger)?;
            }
        }
        
        // Escribir enlaces al archivo temporal
        let mut file = fs::File::create(archivo_path)?;
        for (ruta, destino) in enlaces {
            writeln!(file, "{}\t{}", ruta, destino)?;
        }
        
        // Sincronizar archivo de enlaces a pCloud
        let destino_enlaces = pcloud_dir.join(&self.symlinks_file);
        if let Some(parent) = destino_enlaces.parent() {
            fs::create_dir_all(parent)?;
        }
        
        fs::copy(archivo_path, destino_enlaces)?;
        
        log_info!(logger, "Enlaces detectados/guardados: {}", enlaces.len());
        
        Ok(())
    }
    
    fn procesar_item(
        &self, 
        item: &str, 
        enlaces: &mut HashMap<String, String>,
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
    
    fn registrar_enlace(
        &self,
        enlace_path: &Path,
        item: &str,
        enlaces: &mut HashMap<String, String>,
        logger: &mut Logger
    ) -> Result<()> {
        let destino = fs::read_link(enlace_path)?;
        let destino_str = destino.to_string_lossy().to_string();
        
        // Normalizar destino relativo a HOME
        let destino_normalizado = self.normalizar_destino(&destino_str);
        
        enlaces.insert(item.to_string(), destino_normalizado);
        log_debug!(logger, "Registrado enlace: {} -> {}", item, destino_str);
        
        Ok(())
    }
    
    fn buscar_enlaces_en_directorio(
        &self,
        dir: &Path,
        enlaces: &mut HashMap<String, String>,
        logger: &mut Logger
    ) -> Result<()> {
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_symlink() {
                    if let Ok(relative_path) = path.strip_prefix(&self.local_dir) {
                        self.registrar_enlace(&path, &relative_path.to_string_lossy(), enlaces, logger)?;
                    }
                } else if path.is_dir() {
                    self.buscar_enlaces_en_directorio(&path, enlaces, logger)?;
                }
            }
        }
        
        Ok(())
    }
    
    fn normalizar_destino(&self, destino: &str) -> String {
        if let Ok(home) = std::env::var("HOME") {
            destino.replace(&home, "/home/$USERNAME")
        } else {
            destino.to_string()
        }
    }
    
    pub fn recrear_enlaces_desde_archivo(
        &self,
        pcloud_dir: &Path,
        logger: &mut Logger
    ) -> Result<()> {
        let archivo_enlaces_origen = pcloud_dir.join(&self.symlinks_file);
        let archivo_enlaces_local = self.local_dir.join(&self.symlinks_file);
        
        if !archivo_enlaces_origen.exists() && !archivo_enlaces_local.exists() {
            log_info!(logger, "No se encontró archivo de enlaces, omitiendo recreación");
            return Ok(());
        }
        
        let archivo_a_usar = if archivo_enlaces_origen.exists() {
            fs::copy(&archivo_enlaces_origen, &archivo_enlaces_local)?;
            &archivo_enlaces_local
        } else {
            &archivo_enlaces_local
        };
        
        let contenido = fs::read_to_string(archivo_a_usar)?;
        let mut enlaces_creados = 0;
        let mut enlaces_existentes = 0;
        let mut enlaces_errores = 0;
        
        for linea in contenido.lines() {
            let partes: Vec<&str> = linea.split('\t').collect();
            if partes.len() != 2 {
                continue;
            }
            
            let ruta_enlace = partes[0].trim();
            let destino = partes[1].trim();
            
            if self.procesar_linea_enlace(ruta_enlace, destino, logger)? {
                enlaces_creados += 1;
            } else {
                enlaces_existentes += 1;
            }
        }
        
        fs::remove_file(archivo_enlaces_local).ok(); // Limpiar archivo temporal
        
        log_info!(logger, "Enlaces recreados: {}, Existentes: {}, Errores: {}", 
            enlaces_creados, enlaces_existentes, enlaces_errores);
        
        Ok(())
    }
    
    fn procesar_linea_enlace(
        &self,
        ruta_enlace: &str,
        destino: &str,
        logger: &mut Logger
    ) -> Result<bool> {
        let ruta_completa = self.local_dir.join(ruta_enlace);
        let dir_padre = ruta_completa.parent().unwrap_or(&self.local_dir);
        
        // Crear directorio padre si no existe
        if !dir_padre.exists() {
            fs::create_dir_all(dir_padre)?;
        }
        
        // Expandir variables en el destino
        let destino_expandido = destino.replace("$USERNAME", &whoami::username());
        let destino_expandido = destino_expandido.replace("$HOME", &self.local_dir.to_string_lossy());
        
        // Verificar si el enlace ya existe y es correcto
        if ruta_completa.exists() {
            if let Ok(destino_actual) = fs::read_link(&ruta_completa) {
                if destino_actual.to_string_lossy() == destino_expandido {
                    log_debug!(logger, "Enlace ya existe y es correcto: {}", ruta_enlace);
                    return Ok(false);
                }
            }
            // Eliminar enlace existente incorrecto
            fs::remove_file(&ruta_completa)?;
        }
        
        // Crear el enlace
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            symlink(&destino_expandido, &ruta_completa)?;
        }
        
        #[cfg(windows)]
        {
            use std::os::windows::fs::symlink_file;
            symlink_file(&destino_expandido, &ruta_completa)?;
        }
        
        log_info!(logger, "Creado enlace: {} -> {}", ruta_enlace, destino_expandido);
        Ok(true)
    }
}
