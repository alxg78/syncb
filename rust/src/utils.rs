use std::path::{Path, PathBuf};
use std::process::Command;
use anyhow::{Result, Context};
use sysinfo::{System, SystemExt};
use nix::unistd::Pid;
use std::fs;

pub fn normalize_path(path: &str) -> PathBuf {
    let path_buf = PathBuf::from(path);
    
    // Simplificación básica - en Rust podemos usar canonicalize para rutas existentes
    // Para rutas no existentes, devolvemos la ruta tal cual
    if path_buf.exists() {
        path_buf.canonicalize().unwrap_or(path_buf)
    } else {
        path_buf
    }
}

pub fn verificar_conectividad_pcloud() -> Result<bool> {
    let output = Command::new("curl")
        .args(["-s", "https://www.pcloud.com/"])
        .output();
    
    match output {
        Ok(output) => Ok(output.status.success()),
        Err(_) => {
            // curl no disponible
            Ok(true) // Continuar sin verificación
        }
    }
}

pub fn verificar_pcloud_montado(pcloud_mount_point: &Path) -> Result<bool> {
    if !pcloud_mount_point.exists() {
        return Ok(false);
    }
    
    // Verificar si el directorio está vacío
    if fs::read_dir(pcloud_mount_point)?.next().is_none() {
        return Ok(false);
    }
    
    // Verificar usando mount (simplificado)
    let output = Command::new("mount")
        .output()
        .context("No se pudo ejecutar mount")?;
    
    let mount_output = String::from_utf8_lossy(&output.stdout);
    let mount_point_str = pcloud_mount_point.to_string_lossy();
    
    Ok(mount_output.contains(&mount_point_str))
}

pub fn obtener_info_proceso_lock(pid: i32) -> String {
    let system = System::new_all();
    
    if let Some(process) = system.process(Pid::from_raw(pid)) {
        format!("Dueño del lock: PID {}, Comando: {}, Iniciado: {:?}", 
            pid, process.name(), process.start_time())
    } else {
        format!("Dueño del lock: PID {} (proceso ya terminado)", pid)
    }
}

pub fn establecer_lock(lock_file: &Path, timeout: u64) -> Result<bool> {
    if lock_file.exists() {
        if let Ok(contents) = fs::read_to_string(lock_file) {
            if let Some(first_line) = contents.lines().next() {
                if let Ok(pid) = first_line.parse::<i32>() {
                    // Verificar si el proceso sigue activo
                    let system = System::new_all();
                    if system.process(Pid::from_raw(pid)).is_some() {
                        return Ok(false);
                    }
                }
            }
        }
        
        // Lock obsoleto, eliminarlo
        fs::remove_file(lock_file)?;
    }
    
    let pid = std::process::id();
    let lock_content = format!("{}\nFecha: {}\n", pid, chrono::Local::now());
    
    fs::write(lock_file, lock_content)?;
    Ok(true)
}

pub fn eliminar_lock(lock_file: &Path) -> Result<()> {
    if lock_file.exists() {
        fs::remove_file(lock_file)?;
    }
    Ok(())
}

pub fn confirmar_ejecucion() -> Result<bool> {
    println!("¿Desea continuar con la sincronización? [s/N]: ");
    
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    
    Ok(input.trim().eq_ignore_ascii_case("s"))
}

pub fn verificar_espacio_disco(path: &Path, needed_mb: u64) -> Result<bool> {
    #[cfg(target_os = "linux")]
    {
        use std::os::linux::fs::MetadataExt;
        
        let metadata = fs::metadata(path)?;
        let available = metadata.st_blocks() * metadata.st_blksize() / 1024 / 1024;
        Ok(available >= needed_mb)
    }
    
    #[cfg(target_os = "macos")]
    {
        use std::os::macos::fs::MetadataExt;
        
        let metadata = fs::metadata(path)?;
        let available = metadata.st_blocks() * metadata.st_blksize() / 1024 / 1024;
        Ok(available >= needed_mb)
    }
    
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        // Para otros sistemas, asumir que hay espacio suficiente
        Ok(true)
    }
}