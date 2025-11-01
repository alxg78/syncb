use std::time::{Duration, Instant};
use notify_rust::Notification;

#[derive(Debug, Default)]
pub struct SyncStats {
    pub start_time: Option<Instant>,
    pub items_processed: u32,
    pub files_transferred: u32,
    pub crypto_files_transferred: u32,
    pub files_deleted: u32,
    pub symbolic_links_created: u32,
    pub symbolic_links_existing: u32,
    pub symbolic_links_errors: u32,
    pub symbolic_links_detected: u32,
    pub sync_errors: u32,
    pub total_duration: Duration,
}

impl SyncStats {
    pub fn new() -> Self {
        Self {
            start_time: Some(Instant::now()),
            ..Default::default()
        }
    }
    
    pub fn record_successful_item(&mut self) {
        self.items_processed += 1;
    }
    
    pub fn record_files_transferred(&mut self, count: usize) {
        self.files_transferred += count as u32;
    }
    
    pub fn record_error(&mut self) {
        self.sync_errors += 1;
    }
    
    pub fn display_summary(&self) {
        let duration = self.start_time.map(|t| t.elapsed()).unwrap_or_default();
        
        println!();
        println!("==========================================");
        println!("RESUMEN DE SINCRONIZACIÓN");
        println!("==========================================");
        println!("Elementos procesados: {}", self.items_processed);
        println!("Archivos transferidos: {}", self.files_transferred);
        println!("Archivos Crypto transferidos: {}", self.crypto_files_transferred);
        println!("Archivos borrados: {}", self.files_deleted);
        println!("Enlaces simbólicos:");
        println!("  - Detectados/guardados: {}", self.symbolic_links_detected);
        println!("  - Creados: {}", self.symbolic_links_created);
        println!("  - Existentes: {}", self.symbolic_links_existing);
        println!("  - Errores: {}", self.symbolic_links_errors);
        println!("Errores de sincronización: {}", self.sync_errors);
        println!("Tiempo total: {:.2?}", duration);
        println!("==========================================");
    }
    
    pub fn send_notification(&self) {
        let duration = self.start_time.map(|t| t.elapsed()).unwrap_or_default();
        
        let summary = if self.sync_errors == 0 {
            format!(
                "Sincronización completada con éxito\n• Elementos: {}\n• Transferidos: {}\n• Tiempo: {:.2?}",
                self.items_processed, self.files_transferred, duration
            )
        } else {
            format!(
                "Sincronización completada con errores\n• Errores: {}\n• Elementos: {}\n• Tiempo: {:.2?}",
                self.sync_errors, self.items_processed, duration
            )
        };
        
        let _ = Notification::new()
            .summary("Sincronización syncb")
            .body(&summary)
            .icon("dialog-information")
            .show();
    }
}