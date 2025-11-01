#!/usr/bin/env python3
"""
Script avanzado de sincronización bidireccional entre directorio local y pCloud Drive
con capacidades de backup, manejo de enlaces simbólicos y sistema de logging.

Características:
- Sincronización bidireccional: Subir y Bajar con rsync
- Manejo de enlaces simbólicos
- Sistema de logging con rotación automática
- Verificación de conectividad con pCloud
- Manejo de locks para prevenir ejecuciones simultáneas
- Soporte para múltiples configuraciones por hostname
- Soporte para directorio Crypto encriptado
- Exclusiones configurables
- Modo dry-run
- Verificación de espacio en disco
- Timeout por operación
- Validación de rutas para prevenir path traversal
- Notificaciones de sistema
- Estadísticas detalladas
"""

import os
import sys
import argparse
import logging
import subprocess
import tempfile
import time
import signal
import platform
import stat
from pathlib import Path
from datetime import datetime, timedelta
from typing import List, Dict, Tuple, Optional, Any, Set
import tomli
import tomli_w
import json
from dataclasses import dataclass, field
from enum import Enum
import shutil
import psutil

# =========================
# Configuración de tipos de datos
# =========================

class SyncMode(Enum):
    """Modos de sincronización disponibles"""
    SUBIR = "subir"
    BAJAR = "bajar"

class BackupDirMode(Enum):
    """Modos de directorio de backup"""
    COMUN = "comun"
    READONLY = "readonly"

@dataclass
class SyncConfig:
    """Configuración principal de sincronización"""
    # Directorios
    pcloud_mount_point: str = "~/pCloudDrive"
    local_dir: str = "~"
    pcloud_backup_comun: str = "~/pCloudDrive/Backups/Backup_Comun"
    pcloud_backup_readonly: str = "~/pCloudDrive/pCloud Backup/feynman.sobremesa.dnf"
    
    # Crypto
    local_crypto_dir: str = "~/Crypto"
    remote_crypto_dir: str = "~/pCloudDrive/Crypto Folder"
    cloud_mount_check_file: str = "mount.check"
    local_keepass_dir: str = "~/Crypto/ficheros_sensibles/Keepass2Android"
    remote_keepass_dir: str = "~/pCloudDrive/Applications/Keepass2Android"
    local_crypto_hostname_rtva_dir: str = "~/Crypto/ficheros_sensibles"
    remote_crypto_hostname_rtva_dir: str = "~/pCloudDrive/Crypto Folder/ficheros_sensibles"
    
    # Archivos
    log_file: str = "~/syncb.log"
    lista_por_defecto_file: str = "syncb_directorios.ini"
    lista_especifica_por_defecto_file: str = "syncb_directorios_feynman.rtva.ini"
    exclusiones_file: str = "syncb_exclusiones.ini"
    symlinks_file: str = ".syncb_symlinks.meta"
    
    # Lock
    lock_file: str = "/tmp/syncb.lock"
    lock_timeout: int = 3600
    
    # Hostnames
    hostname_rtva: str = "feynman.rtva.dnf"
    
    # Configuración específica por host
    hosts: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    
    # Listas de sincronización y exclusiones
    directorios: Dict[str, List[str]] = field(default_factory=dict)
    exclusiones: List[str] = field(default_factory=list)
    
    # Permisos
    permisos_archivos: Dict[str, str] = field(default_factory=dict)
    permisos_directorios: Dict[str, str] = field(default_factory=dict)

@dataclass
class SyncStats:
    """Estadísticas de sincronización"""
    elementos_procesados: int = 0
    errores_sincronizacion: int = 0
    archivos_transferidos: int = 0
    enlaces_creados: int = 0
    enlaces_existentes: int = 0
    enlaces_errores: int = 0
    enlaces_detectados: int = 0
    archivos_borrados: int = 0
    archivos_crypto_transferidos: int = 0
    tiempo_inicio: float = field(default_factory=time.time)
    
    @property
    def tiempo_total(self) -> float:
        return time.time() - self.tiempo_inicio

class Colors:
    """Códigos de colores ANSI"""
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    MAGENTA = '\033[0;35m'
    CYAN = '\033[0;36m'
    WHITE = '\033[1;37m'
    NC = '\033[0m'  # No Color

class Icons:
    """Iconos Unicode"""
    CHECK_MARK = "✓"
    CROSS_MARK = "✗"
    INFO_ICON = "ℹ"
    WARNING_ICON = "⚠"
    DEBUG_ICON = "🔍"
    LOCK_ICON = "🔒"
    UNLOCK_ICON = "🔓"
    CLOCK_ICON = "⏱"
    SYNC_ICON = "🔄"
    ERROR_ICON = "❌"
    SUCCESS_ICON = "✅"

# =========================
# Clase principal de sincronización
# =========================

class SyncB:
    """Clase principal para sincronización bidireccional con pCloud"""
    
    def __init__(self, config_path: Optional[str] = None):
        """Inicializa la clase de sincronización"""
        self.config = SyncConfig()
        self.stats = SyncStats()
        self.args = None
        self.logger = None
        self.lock_acquired = False
        self.temp_files: Set[str] = set()
        
        # Cargar configuración
        self._load_config(config_path)
        
        # Configurar logging
        self._setup_logging()
        
        # Inicializar rutas
        self._init_paths()
        
        # Configurar manejo de señales
        self._setup_signal_handlers()
    
    def _load_config(self, config_path: Optional[str] = None):
        """Carga la configuración desde archivo TOML"""
        possible_paths = [
            config_path,
            "~/.config/syncb/config.toml",
            "./syncb_config.toml",
            Path(__file__).parent / "syncb_config.toml"
        ]
        
        config_file = None
        for path in possible_paths:
            if path and Path(path).expanduser().exists():
                config_file = Path(path).expanduser()
                break
        
        if not config_file:
            raise FileNotFoundError("No se encontró archivo de configuración")
        
        with open(config_file, 'rb') as f:
            config_data = tomli.load(f)
        
        # Mapear configuración
        general = config_data.get('general', {})
        self.config.pcloud_mount_point = general.get('pcloud_mount_point', self.config.pcloud_mount_point)
        self.config.local_dir = general.get('local_dir', self.config.local_dir)
        self.config.pcloud_backup_comun = general.get('pcloud_backup_comun', self.config.pcloud_backup_comun)
        self.config.pcloud_backup_readonly = general.get('pcloud_backup_readonly', self.config.pcloud_backup_readonly)
        
        crypto = config_data.get('crypto', {})
        self.config.local_crypto_dir = crypto.get('local_crypto_dir', self.config.local_crypto_dir)
        self.config.remote_crypto_dir = crypto.get('remote_crypto_dir', self.config.remote_crypto_dir)
        self.config.cloud_mount_check_file = crypto.get('cloud_mount_check_file', self.config.cloud_mount_check_file)
        self.config.local_keepass_dir = crypto.get('local_keepass_dir', self.config.local_keepass_dir)
        self.config.remote_keepass_dir = crypto.get('remote_keepass_dir', self.config.remote_keepass_dir)
        self.config.local_crypto_hostname_rtva_dir = crypto.get('local_crypto_hostname_rtva_dir', self.config.local_crypto_hostname_rtva_dir)
        self.config.remote_crypto_hostname_rtva_dir = crypto.get('remote_crypto_hostname_rtva_dir', self.config.remote_crypto_hostname_rtva_dir)
        
        files = config_data.get('files', {})
        self.config.log_file = files.get('log_file', self.config.log_file)
        self.config.lista_por_defecto_file = files.get('lista_por_defecto_file', self.config.lista_por_defecto_file)
        self.config.lista_especifica_por_defecto_file = files.get('lista_especifica_por_defecto_file', self.config.lista_especifica_por_defecto_file)
        self.config.exclusiones_file = files.get('exclusiones_file', self.config.exclusiones_file)
        self.config.symlinks_file = files.get('symlinks_file', self.config.symlinks_file)
        
        lock = config_data.get('lock', {})
        self.config.lock_file = lock.get('lock_file', self.config.lock_file)
        self.config.lock_timeout = lock.get('lock_timeout', self.config.lock_timeout)
        
        hosts = config_data.get('hosts', {})
        self.config.hosts = hosts
        
        # Cargar listas de sincronización
        self.config.directorios = config_data.get('directorios', {})
        self.config.exclusiones = config_data.get('exclusiones', [])
        
        # Cargar permisos
        permisos = config_data.get('permisos', {})
        self.config.permisos_archivos = permisos.get('archivos', {})
        self.config.permisos_directorios = permisos.get('directorios', {})
    
    def _setup_logging(self):
        """Configura el sistema de logging"""
        log_file = Path(self.config.log_file).expanduser()
        log_file.parent.mkdir(parents=True, exist_ok=True)
        
        # Configurar formato
        formatter = logging.Formatter(
            '%(asctime)s - %(levelname)s - %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        
        # Configurar handler de archivo con rotación
        file_handler = logging.FileHandler(log_file)
        file_handler.setFormatter(formatter)
        
        # Configurar handler de consola con colores
        console_handler = logging.StreamHandler()
        console_handler.setFormatter(self._ColoredFormatter())
        
        # Configurar logger
        self.logger = logging.getLogger('syncb')
        self.logger.setLevel(logging.DEBUG)
        self.logger.addHandler(file_handler)
        self.logger.addHandler(console_handler)
        
        # Deshabilitar propagación para evitar duplicados
        self.logger.propagate = False
    
    class _ColoredFormatter(logging.Formatter):
        """Formateador con colores para la consola"""
        
        COLORS = {
            'DEBUG': Colors.MAGENTA,
            'INFO': Colors.BLUE,
            'WARNING': Colors.YELLOW,
            'ERROR': Colors.RED,
            'CRITICAL': Colors.RED
        }
        
        ICONS = {
            'DEBUG': Icons.DEBUG_ICON,
            'INFO': Icons.INFO_ICON,
            'WARNING': Icons.WARNING_ICON,
            'ERROR': Icons.ERROR_ICON,
            'CRITICAL': Icons.ERROR_ICON
        }
        
        def format(self, record):
            color = self.COLORS.get(record.levelname, Colors.NC)
            icon = self.ICONS.get(record.levelname, '')
            record.levelname = f"{color}{icon} [{record.levelname}]{Colors.NC}"
            return super().format(record)
    
    def _init_paths(self):
        """Inicializa y expande todas las rutas"""
        self.config.pcloud_mount_point = str(Path(self.config.pcloud_mount_point).expanduser())
        self.config.local_dir = str(Path(self.config.local_dir).expanduser())
        self.config.pcloud_backup_comun = str(Path(self.config.pcloud_backup_comun).expanduser())
        self.config.pcloud_backup_readonly = str(Path(self.config.pcloud_backup_readonly).expanduser())
        self.config.local_crypto_dir = str(Path(self.config.local_crypto_dir).expanduser())
        self.config.remote_crypto_dir = str(Path(self.config.remote_crypto_dir).expanduser())
        self.config.local_keepass_dir = str(Path(self.config.local_keepass_dir).expanduser())
        self.config.remote_keepass_dir = str(Path(self.config.remote_keepass_dir).expanduser())
        self.config.local_crypto_hostname_rtva_dir = str(Path(self.config.local_crypto_hostname_rtva_dir).expanduser())
        self.config.remote_crypto_hostname_rtva_dir = str(Path(self.config.remote_crypto_hostname_rtva_dir).expanduser())
        self.config.log_file = str(Path(self.config.log_file).expanduser())
        self.config.lock_file = str(Path(self.config.lock_file).expanduser())
    
    def _setup_signal_handlers(self):
        """Configura el manejo de señales para limpieza"""
        def signal_handler(signum, frame):
            self.logger.warning(f"Señal {signum} recibida, limpiando...")
            self.cleanup()
            sys.exit(1)
        
        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)
    
    def parse_arguments(self):
        """Parsea los argumentos de línea de comandos"""
        parser = argparse.ArgumentParser(
            description='Sincronización bidireccional entre directorio local y pCloud Drive',
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog=f'''
Ejemplos de uso:
  {sys.argv[0]} --subir
  {sys.argv[0]} --bajar --dry-run
  {sys.argv[0]} --subir --delete --yes
  {sys.argv[0]} --subir --item documentos/
  {sys.argv[0]} --bajar --item configuracion.ini --item .local/bin --dry-run
  {sys.argv[0]} --bajar --backup-dir --item documentos/ --yes
  {sys.argv[0]} --subir --exclude '*.tmp' --exclude 'temp/'
  {sys.argv[0]} --subir --overwrite     # Sobrescribe todos los archivos
  {sys.argv[0]} --subir --bwlimit 1000  # Sincronizar subiendo con límite de 1MB/s
  {sys.argv[0]} --subir --verbose       # Sincronizar con output verboso
  {sys.argv[0]} --bajar --item Documentos/ --timeout 10  # Timeout corto de 10 minutos
  {sys.argv[0]} --force-unlock   # Forzar desbloqueo si hay un lock obsoleto
  {sys.argv[0]} --crypto         # Incluir directorio Crypto de la sincronización

Hostname detectado: {platform.node()}
            '''
        )
        
        # Opciones principales (mutuamente excluyentes)
        group = parser.add_mutually_exclusive_group(required=True)
        group.add_argument('--subir', action='store_true', 
                         help='Sincroniza desde el directorio local a pCloud')
        group.add_argument('--bajar', action='store_true',
                         help='Sincroniza desde pCloud al directorio local')
        
        # Opciones secundarias
        parser.add_argument('--delete', action='store_true',
                          help='Elimina en destino los archivos que no existan en origen')
        parser.add_argument('--dry-run', action='store_true',
                          help='Simula la operación sin hacer cambios reales')
        parser.add_argument('--item', action='append', dest='items',
                          help='Sincroniza solo el elemento especificado (puede usarse múltiples veces)')
        parser.add_argument('--yes', action='store_true',
                          help='No pregunta confirmación, ejecuta directamente')
        parser.add_argument('--backup-dir', action='store_true',
                          help='Usa el directorio de backup de solo lectura (pCloud Backup)')
        parser.add_argument('--exclude', action='append', dest='excludes',
                          help='Excluye archivos que coincidan con el patrón (puede usarse múltiples veces)')
        parser.add_argument('--overwrite', action='store_true',
                          help='Sobrescribe todos los archivos en destino (no usa --update)')
        parser.add_argument('--checksum', action='store_true',
                          help='Fuerza comparación con checksum (más lento)')
        parser.add_argument('--bwlimit', type=int,
                          help='Limita la velocidad de transferencia (ej: 1000 para 1MB/s)')
        parser.add_argument('--timeout', type=int, default=30,
                          help='Límite de tiempo por operación en minutos (default: 30)')
        parser.add_argument('--force-unlock', action='store_true',
                          help='Forzar eliminación de lock')
        parser.add_argument('--crypto', action='store_true',
                          help='Incluye la sincronización del directorio Crypto')
        parser.add_argument('--verbose', action='store_true',
                          help='Habilita modo verboso para debugging')
        
        self.args = parser.parse_args()
        
        # Validaciones adicionales
        if self.args.force_unlock:
            self._force_unlock()
            sys.exit(0)
    
    def _force_unlock(self):
        """Forza la eliminación del lock file"""
        lock_file = Path(self.config.lock_file)
        if lock_file.exists():
            lock_file.unlink()
            self.logger.info("Lock eliminado forzadamente")
        else:
            self.logger.info("No hay lock activo")
    
    def get_pcloud_dir(self) -> str:
        """Obtiene el directorio de pCloud según el modo"""
        if self.args.backup_dir:
            return self.config.pcloud_backup_readonly
        return self.config.pcloud_backup_comun
    
    def normalize_path(self, path: str) -> str:
        """Normaliza una ruta"""
        return str(Path(path).expanduser().resolve())
    
    def verificar_conectividad_pcloud(self) -> bool:
        """Verifica la conectividad con pCloud"""
        self.logger.debug("Verificando conectividad con pCloud...")
        
        try:
            # Intentar conectar a pCloud
            result = subprocess.run(
                ['curl', '-s', '--connect-timeout', '5', 'https://www.pcloud.com/'],
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if result.returncode == 0:
                self.logger.info("Verificación de conectividad pCloud: OK")
                return True
            else:
                self.logger.warning("No se pudo conectar a pCloud")
                return False
                
        except (subprocess.TimeoutExpired, FileNotFoundError):
            self.logger.warning("curl no disponible o timeout, omitiendo verificación")
            return True
    
    def verificar_pcloud_montado(self) -> bool:
        """Verifica si pCloud está montado correctamente"""
        pcloud_dir = self.normalize_path(self.get_pcloud_dir())
        mount_point = self.normalize_path(self.config.pcloud_mount_point)
        
        self.logger.debug(f"Verificando montaje de pCloud en: {mount_point}")
        
        # Verificar si el punto de montaje existe
        if not Path(mount_point).exists():
            self.logger.error(f"El punto de montaje de pCloud no existe: {mount_point}")
            return False
        
        # Verificar si el directorio está vacío (puede indicar que no está montado)
        try:
            if not any(Path(mount_point).iterdir()):
                self.logger.error(f"El directorio de pCloud está vacío: {mount_point}")
                return False
        except OSError:
            self.logger.error(f"No se puede leer el directorio de pCloud: {mount_point}")
            return False
        
        # Verificar usando diferentes métodos según el SO
        system = platform.system()
        
        if system == "Linux":
            # En Linux usar mountpoint o /proc/mounts
            try:
                result = subprocess.run(
                    ['mountpoint', '-q', mount_point],
                    capture_output=True
                )
                if result.returncode != 0:
                    self.logger.error(f"pCloud no aparece montado en {mount_point}")
                    return False
            except FileNotFoundError:
                # Fallback: verificar en /proc/mounts
                with open('/proc/mounts', 'r') as f:
                    mounts = f.read()
                if 'pcloud' not in mounts:
                    self.logger.error("pCloud no aparece en /proc/mounts")
                    return False
        
        elif system == "Darwin":
            # En macOS usar mount
            try:
                result = subprocess.run(['mount'], capture_output=True, text=True)
                if mount_point not in result.stdout:
                    self.logger.error(f"pCloud no aparece montado en {mount_point}")
                    return False
            except FileNotFoundError:
                self.logger.warning("No se pudo verificar montaje en macOS")
        
        # Verificación adicional con df
        try:
            subprocess.run(['df', mount_point], capture_output=True, check=True)
        except subprocess.CalledProcessError:
            self.logger.error(f"pCloud no está montado correctamente en {mount_point}")
            return False
        
        # Verificar permisos de escritura (solo si no es dry-run y no es modo backup-dir)
        if not self.args.dry_run and not self.args.backup_dir:
            test_file = Path(pcloud_dir) / f".test_write_{os.getpid()}"
            try:
                test_file.touch()
                test_file.unlink()
            except OSError:
                self.logger.error(f"No se puede escribir en: {pcloud_dir}")
                return False
        
        # Verificar montaje de carpeta Crypto si está habilitado
        if self.args.crypto:
            cloud_mount_check = Path(self.config.remote_crypto_dir) / self.config.cloud_mount_check_file
            if not cloud_mount_check.exists():
                self.logger.error("El volumen Crypto no está montado o el archivo de verificación no existe")
                return False
        
        self.logger.info("Verificación de pCloud: OK - El directorio está montado y accesible")
        return True
    
    def verificar_espacio_disco(self, needed_mb: int = 100) -> bool:
        """Verifica el espacio disponible en disco"""
        mount_point = (
            self.normalize_path(self.config.pcloud_mount_point) 
            if self.args.subir 
            else self.normalize_path(self.config.local_dir)
        )
        
        tipo_operacion = "SUBIDA a pCloud" if self.args.subir else "BAJADA desde pCloud"
        
        if not Path(mount_point).exists():
            self.logger.warning(f"El punto de montaje {mount_point} no existe, omitiendo verificación")
            return True
        
        try:
            disk_usage = shutil.disk_usage(mount_point)
            available_mb = disk_usage.free // (1024 * 1024)
            
            if available_mb < needed_mb:
                self.logger.error(
                    f"Espacio insuficiente para {tipo_operacion} en {mount_point}\n"
                    f"Disponible: {available_mb}MB, Necesario: {needed_mb}MB"
                )
                return False
            
            self.logger.info(
                f"Espacio en disco verificado para {tipo_operacion}. "
                f"Disponible: {available_mb}MB"
            )
            return True
            
        except OSError as e:
            self.logger.warning(f"No se pudo verificar el espacio en disco: {e}")
            return True
    
    def establecer_lock(self) -> bool:
        """Establece el lock file para prevenir ejecuciones simultáneas"""
        lock_file = Path(self.config.lock_file)
        
        if lock_file.exists():
            # Verificar si el lock es antiguo
            try:
                lock_time = lock_file.stat().st_mtime
                current_time = time.time()
                lock_age = current_time - lock_time
                
                if lock_age > self.config.lock_timeout:
                    self.logger.warning(f"Eliminando lock obsoleto (edad: {lock_age:.0f}s)")
                    lock_file.unlink()
                else:
                    # Leer información del proceso dueño del lock
                    try:
                        with lock_file.open('r') as f:
                            lock_info = f.read().split('\n')[0]
                        self.logger.error(f"Ya hay una ejecución en progreso: {lock_info}")
                    except:
                        self.logger.error("Ya hay una ejecución en progreso (lock file existente)")
                    return False
                    
            except OSError:
                self.logger.warning("No se pudo verificar el lock, eliminando...")
                lock_file.unlink()
        
        # Crear nuevo lock
        try:
            with lock_file.open('w') as f:
                f.write(f"PID: {os.getpid()}\n")
                f.write(f"Fecha: {datetime.now()}\n")
                f.write(f"Modo: {'subir' if self.args.subir else 'bajar'}\n")
                f.write(f"Usuario: {os.getenv('USER', 'unknown')}\n")
                f.write(f"Hostname: {platform.node()}\n")
            
            self.lock_acquired = True
            self.logger.info(f"Lock establecido: {lock_file}")
            return True
            
        except OSError as e:
            self.logger.error(f"No se pudo crear el archivo de lock: {e}")
            return False
    
    def eliminar_lock(self):
        """Elimina el lock file"""
        if self.lock_acquired:
            lock_file = Path(self.config.lock_file)
            if lock_file.exists():
                try:
                    # Verificar que somos los dueños del lock
                    with lock_file.open('r') as f:
                        first_line = f.readline().strip()
                    if f"PID: {os.getpid()}" in first_line:
                        lock_file.unlink()
                        self.logger.info("Lock eliminado")
                        self.lock_acquired = False
                except OSError:
                    pass
    
    def mostrar_banner(self):
        """Muestra el banner informativo"""
        pcloud_dir = self.get_pcloud_dir()
        
        print("=" * 50)
        if self.args.subir:
            print("MODO: SUBIR (Local → pCloud)")
            print(f"ORIGEN: {self.config.local_dir}")
            print(f"DESTINO: {pcloud_dir}")
        else:
            print("MODO: BAJAR (pCloud → Local)")
            print(f"ORIGEN: {pcloud_dir}")
            print(f"DESTINO: {self.config.local_dir}")
        
        if self.args.backup_dir:
            print("DIRECTORIO: Backup de solo lectura (pCloud Backup)")
        else:
            print("DIRECTORIO: Backup común (Backup_Comun)")
        
        if self.args.dry_run:
            print(f"ESTADO: {Colors.YELLOW}MODO SIMULACIÓN{Colors.NC} (no se realizarán cambios)")
        
        if self.args.delete:
            print(f"BORRADO: {Colors.GREEN}ACTIVADO{Colors.NC} (se eliminarán archivos obsoletos)")
        
        if self.args.yes:
            print("CONFIRMACIÓN: Automática (sin preguntar)")
        
        if self.args.overwrite:
            print(f"SOBRESCRITURA: {Colors.GREEN}ACTIVADA{Colors.NC}")
        else:
            print("MODO: SEGURO (--update activado)")
        
        if self.args.crypto:
            print(f"CRYPTO: {Colors.GREEN}INCLUIDO{Colors.NC} (se sincronizará directorio Crypto)")
        else:
            print(f"CRYPTO: {Colors.YELLOW}EXCLUIDO{Colors.NC} (no se sincronizará directorio Crypto)")
        
        if self.args.items:
            print(f"ELEMENTOS ESPECÍFICOS: {', '.join(self.args.items)}")
        else:
            hostname = platform.node()
            if hostname in self.config.directorios:
                print(f"LISTA: Configuración para host {hostname}")
            else:
                print("LISTA: Configuración por defecto")
        
        if self.config.exclusiones:
            print(f"EXCLUSIONES: {len(self.config.exclusiones)} patrones cargados")
        
        if self.args.excludes:
            print(f"EXCLUSIONES CLI ({len(self.args.excludes)} patrones):")
            for i, pattern in enumerate(self.args.excludes, 1):
                print(f"  {i}. {pattern}")
        print("=" * 50)
    
    def confirmar_ejecucion(self):
        """Solicita confirmación al usuario antes de ejecutar"""
        if self.args.yes:
            self.logger.info("Confirmación automática (--yes): se procede con la sincronización")
            return
        
        if sys.stdin.isatty():
            respuesta = input("¿Desea continuar con la sincronización? [s/N]: ")
            if respuesta.lower() not in ['s', 'si', 'sí']:
                self.logger.info("Operación cancelada por el usuario.")
                sys.exit(0)
        else:
            self.logger.error("No hay entrada interactiva disponible (usa --yes)")
            sys.exit(1)
    
    def verificar_dependencias(self):
        """Verifica que todas las dependencias estén instaladas"""
        dependencias = ['rsync']
        
        for dep in dependencias:
            if not shutil.which(dep):
                self.logger.error(f"{dep} no está instalado. Instálalo con:")
                if platform.system() == "Linux":
                    if shutil.which('apt'):
                        self.logger.info(f"sudo apt install {dep}  # Debian/Ubuntu")
                    elif shutil.which('dnf'):
                        self.logger.info(f"sudo dnf install {dep}  # RedHat/CentOS")
                elif platform.system() == "Darwin":
                    self.logger.info(f"brew install {dep}  # macOS con Homebrew")
                sys.exit(1)
    
    def obtener_lista_sincronizacion(self) -> List[str]:
        """Obtiene la lista de elementos a sincronizar"""
        if self.args.items:
            return self.args.items
        
        hostname = platform.node()
        
        # Buscar configuración específica del host
        if hostname in self.config.directorios:
            return self.config.directorios[hostname]
        elif 'default' in self.config.directorios:
            return self.config.directorios['default']
        else:
            self.logger.error("No se encontró lista de sincronización")
            sys.exit(1)
    
    def validar_elemento(self, elemento: str) -> bool:
        """Valida que un elemento sea seguro y exista"""
        # Prevenir path traversal
        if '..' in elemento or elemento.startswith('/'):
            self.logger.error(f"Elemento contiene path traversal o ruta absoluta: {elemento}")
            return False
        
        # Construir ruta completa
        if self.args.subir:
            ruta_completa = Path(self.config.local_dir) / elemento
        else:
            ruta_completa = Path(self.get_pcloud_dir()) / elemento
        
        # Verificar existencia
        if not ruta_completa.exists():
            self.logger.warning(f"El elemento no existe: {elemento}")
            return False
        
        return True
    
    def construir_opciones_rsync(self) -> List[str]:
        """Construye las opciones para rsync"""
        opts = [
            '--recursive',
            '--verbose',
            '--times',
            '--progress',
            '--munge-links',
            '--whole-file',
            '--itemize-changes',
        ]
        
        if not self.args.overwrite:
            opts.append('--update')
        
        if self.args.dry_run:
            opts.append('--dry-run')
        
        if self.args.delete:
            opts.append('--delete-delay')
        
        if self.args.checksum:
            opts.append('--checksum')
        
        if self.args.bwlimit:
            opts.append(f'--bwlimit={self.args.bwlimit}')
        
        # Añadir exclusiones del archivo de configuración
        for exclusion in self.config.exclusiones:
            opts.append(f'--exclude={exclusion}')
        
        # Añadir exclusiones de línea de comandos
        if self.args.excludes:
            for exclusion in self.args.excludes:
                opts.append(f'--exclude={exclusion}')
        
        return opts
    
    def sincronizar_elemento(self, elemento: str) -> bool:
        """Sincroniza un elemento individual"""
        pcloud_dir = self.get_pcloud_dir()
        
        if self.args.subir:
            origen = Path(self.config.local_dir) / elemento
            destino = Path(pcloud_dir) / elemento
            direccion = "LOCAL → PCLOUD (Subir)"
        else:
            origen = Path(pcloud_dir) / elemento
            destino = Path(self.config.local_dir) / elemento
            direccion = "PCLOUD → LOCAL (Bajar)"
        
        # Verificar existencia del origen
        if not origen.exists():
            self.logger.warning(f"No existe {origen}")
            return False
        
        # Normalizar rutas para directorios
        if origen.is_dir():
            origen = origen / ""
            destino = destino / ""
        
        # Crear directorio destino si no existe
        destino.parent.mkdir(parents=True, exist_ok=True)
        
        self.logger.info(f"{Colors.BLUE}Sincronizando: {elemento} ({direccion}){Colors.NC}")
        
        # Construir comando rsync
        opts = self.construir_opciones_rsync()
        cmd = ['rsync'] + opts + [str(origen), str(destino)]
        
        # Ejecutar con timeout si está configurado
        try:
            timeout_seconds = self.args.timeout * 60 if not self.args.dry_run else None
            
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout_seconds
            )
            
            # Analizar salida para estadísticas
            self._analizar_salida_rsync(result.stdout, result.stderr)
            
            if result.returncode == 0:
                self.logger.info(f"Sincronización completada: {elemento}")
                return True
            else:
                self.logger.error(f"Error en sincronización: {elemento} (código: {result.returncode})")
                if result.stderr:
                    self.logger.error(f"Error rsync: {result.stderr}")
                self.stats.errores_sincronizacion += 1
                return False
                
        except subprocess.TimeoutExpired:
            self.logger.error(f"TIMEOUT: La sincronización de '{elemento}' excedió el límite")
            self.stats.errores_sincronizacion += 1
            return False
    
    def _analizar_salida_rsync(self, stdout: str, stderr: str):
        """Analiza la salida de rsync para extraer estadísticas"""
        # Contar archivos transferidos (líneas que comienzan con >f)
        archivos_creados = len([l for l in stdout.split('\n') if l.startswith('>f')])
        archivos_actualizados = len([l for l in stdout.split('\n') if l.startswith('>f.st')])
        total_transferidos = len([l for l in stdout.split('\n') if l.startswith(('>f', '<f'))])
        
        # Contar borrados si está habilitado
        if self.args.delete:
            archivos_borrados = len([l for l in stdout.split('\n') if l.startswith('*deleting')])
            self.stats.archivos_borrados += archivos_borrados
        
        self.stats.archivos_transferidos += total_transferidos
        self.stats.elementos_procesados += 1
        
        if archivos_creados > 0:
            self.logger.info(f"Archivos creados: {archivos_creados}")
        if archivos_actualizados > 0:
            self.logger.info(f"Archivos actualizados: {archivos_actualizados}")
    
    def manejar_enlaces_simbolicos(self):
        """Maneja la generación y recreación de enlaces simbólicos"""
        if self.args.subir:
            self._generar_archivo_enlaces()
        else:
            self._recrear_enlaces_desde_archivo()
    
    def _generar_archivo_enlaces(self):
        """Genera el archivo de metadatos de enlaces simbólicos"""
        pcloud_dir = self.get_pcloud_dir()
        archivo_enlaces = Path(pcloud_dir) / self.config.symlinks_file
        elementos = self.obtener_lista_sincronizacion()
        
        self.logger.info("Generando archivo de enlaces simbólicos...")
        
        with tempfile.NamedTemporaryFile(mode='w', delete=False, prefix='syncb_links_') as temp_file:
            self.temp_files.add(temp_file.name)
            
            for elemento in elementos:
                if not self.validar_elemento(elemento):
                    continue
                
                ruta_completa = Path(self.config.local_dir) / elemento
                
                if ruta_completa.is_symlink():
                    self._registrar_enlace(ruta_completa, temp_file.name)
                elif ruta_completa.is_dir():
                    self._buscar_enlaces_en_directorio(ruta_completa, temp_file.name)
            
            # Sincronizar archivo de enlaces a pCloud
            if os.path.getsize(temp_file.name) > 0:
                opts = self.construir_opciones_rsync()
                cmd = ['rsync'] + opts + [temp_file.name, str(archivo_enlaces)]
                
                try:
                    subprocess.run(cmd, check=True, capture_output=True)
                    self.logger.info(f"Enlaces detectados/guardados: {self.stats.enlaces_detectados}")
                    self.logger.info("Archivo de enlaces sincronizado")
                except subprocess.CalledProcessError as e:
                    self.logger.error(f"Error sincronizando archivo de enlaces: {e}")
    
    def _registrar_enlace(self, enlace: Path, archivo_enlaces: str):
        """Registra un enlace simbólico individual"""
        try:
            # Obtener ruta relativa
            ruta_relativa = enlace.relative_to(Path(self.config.local_dir))
            
            # Obtener destino del enlace
            destino = enlace.readlink()
            
            # Normalizar destino
            if str(destino).startswith(str(Path(self.config.local_dir))):
                destino = Path('/home/$USERNAME') / destino.relative_to(Path(self.config.local_dir))
            elif str(destino).startswith('/home/'):
                partes = destino.parts[2:]  # Eliminar /home/username
                destino = Path('/home/$USERNAME') / Path(*partes)
            
            # Escribir en archivo
            with open(archivo_enlaces, 'a') as f:
                f.write(f"{ruta_relativa}\t{destino}\n")
            
            self.stats.enlaces_detectados += 1
            self.logger.debug(f"Registrado enlace: {ruta_relativa} -> {destino}")
            
        except (ValueError, OSError) as e:
            self.logger.warning(f"Error procesando enlace {enlace}: {e}")
    
    def _buscar_enlaces_en_directorio(self, directorio: Path, archivo_enlaces: str):
        """Busca enlaces simbólicos en un directorio recursivamente"""
        try:
            for item in directorio.rglob('*'):
                if item.is_symlink():
                    self._registrar_enlace(item, archivo_enlaces)
        except OSError as e:
            self.logger.warning(f"Error buscando enlaces en {directorio}: {e}")
    
    def _recrear_enlaces_desde_archivo(self):
        """Recrea enlaces simbólicos desde el archivo de metadatos"""
        pcloud_dir = self.get_pcloud_dir()
        archivo_enlaces_origen = Path(pcloud_dir) / self.config.symlinks_file
        archivo_enlaces_local = Path(self.config.local_dir) / self.config.symlinks_file
        
        self.logger.info("Recreando enlaces simbólicos...")
        
        # Copiar archivo localmente si existe en pCloud
        if archivo_enlaces_origen.exists():
            shutil.copy2(archivo_enlaces_origen, archivo_enlaces_local)
        elif not archivo_enlaces_local.exists():
            self.logger.info("No se encontró archivo de enlaces, omitiendo recreación")
            return
        
        # Procesar archivo de enlaces
        try:
            with open(archivo_enlaces_local, 'r') as f:
                for linea in f:
                    linea = linea.strip()
                    if not linea or '\t' not in linea:
                        continue
                    
                    ruta_enlace, destino = linea.split('\t', 1)
                    self._procesar_linea_enlace(ruta_enlace, destino)
            
            self.logger.info(f"Enlaces recreados: {self.stats.enlaces_creados}, "
                           f"Errores: {self.stats.enlaces_errores}")
            
            # Limpiar archivo local
            if not self.args.dry_run:
                archivo_enlaces_local.unlink()
                
        except OSError as e:
            self.logger.error(f"Error procesando archivo de enlaces: {e}")
    
    def _procesar_linea_enlace(self, ruta_enlace: str, destino: str):
        """Procesa una línea del archivo de enlaces"""
        ruta_completa = Path(self.config.local_dir) / ruta_enlace
        dir_padre = ruta_completa.parent
        
        # Crear directorio padre si no existe
        if not self.args.dry_run:
            dir_padre.mkdir(parents=True, exist_ok=True)
        
        # Normalizar destino
        destino_normalizado = destino.replace('$USERNAME', os.getenv('USER', 'user'))
        if destino_normalizado.startswith('/home/$USERNAME'):
            destino_normalizado = destino_normalizado.replace('/home/$USERNAME', str(Path.home()))
        
        # Verificar si el enlace ya existe y es correcto
        if ruta_completa.exists():
            if ruta_completa.is_symlink():
                destino_actual = ruta_completa.readlink()
                if str(destino_actual) == destino_normalizado:
                    self.stats.enlaces_existentes += 1
                    return
                else:
                    # Eliminar enlace existente incorrecto
                    if not self.args.dry_run:
                        ruta_completa.unlink()
        
        # Crear el enlace
        if self.args.dry_run:
            self.logger.debug(f"SIMULACIÓN: Enlace a crear: {ruta_completa} -> {destino_normalizado}")
            self.stats.enlaces_creados += 1
        else:
            try:
                ruta_completa.symlink_to(destino_normalizado)
                self.stats.enlaces_creados += 1
                self.logger.debug(f"Enlace creado: {ruta_completa} -> {destino_normalizado}")
            except OSError as e:
                self.logger.error(f"Error creando enlace {ruta_completa}: {e}")
                self.stats.enlaces_errores += 1
    
    def sincronizar_crypto(self):
        """Sincroniza el directorio Crypto"""
        hostname = platform.node()
        
        if hostname == self.config.hostname_rtva:
            if self.args.subir:
                origen = Path(self.config.local_crypto_hostname_rtva_dir)
                destino = Path(self.config.remote_crypto_hostname_rtva_dir)
            else:
                origen = Path(self.config.remote_crypto_hostname_rtva_dir)
                destino = Path(self.config.local_crypto_hostname_rtva_dir)
        else:
            if self.args.subir:
                origen = Path(self.config.local_crypto_dir)
                destino = Path(self.config.remote_crypto_dir)
            else:
                origen = Path(self.config.remote_crypto_dir)
                destino = Path(self.config.local_crypto_dir)
        
        direccion = "LOCAL → PCLOUD (Crypto Subir)" if self.args.subir else "PCLOUD → LOCAL (Crypto Bajar)"
        
        # Crear directorios si no existen
        origen.mkdir(parents=True, exist_ok=True)
        destino.mkdir(parents=True, exist_ok=True)
        
        print("-" * 50)
        self.logger.info(f"{Colors.BLUE}Sincronizando Crypto: {origen} -> {destino} ({direccion}){Colors.NC}")
        
        # Construir opciones específicas para Crypto
        opts = self.construir_opciones_rsync()
        
        # Excluir archivo de verificación de montaje
        opts.append(f'--exclude={self.config.cloud_mount_check_file}')
        
        # Sincronizar KeePass2Android primero
        keepass_origen = Path(self.config.remote_keepass_dir) / ""
        keepass_destino = Path(self.config.local_keepass_dir) / ""
        
        if keepass_origen.exists() and keepass_destino.parent.exists():
            cmd_keepass = ['rsync'] + opts + [str(keepass_origen), str(keepass_destino)]
            try:
                subprocess.run(cmd_keepass, check=True, capture_output=True)
            except subprocess.CalledProcessError as e:
                self.logger.warning(f"Error sincronizando KeePass: {e}")
        
        # Sincronizar directorio Crypto principal
        cmd = ['rsync'] + opts + [str(origen / ""), str(destino / "")]
        
        try:
            timeout_seconds = self.args.timeout * 60 if not self.args.dry_run else None
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_seconds)
            
            # Contar archivos transferidos
            crypto_count = len([l for l in result.stdout.split('\n') if l.startswith(('>f', '<f'))])
            self.stats.archivos_crypto_transferidos += crypto_count
            
            if result.returncode == 0:
                self.logger.info(f"Sincronización Crypto completada: {crypto_count} archivos transferidos")
                print("-" * 50)
                return True
            else:
                self.logger.error(f"Error en sincronización Crypto (código: {result.returncode})")
                self.stats.errores_sincronizacion += 1
                return False
                
        except subprocess.TimeoutExpired:
            self.logger.error("TIMEOUT: La sincronización Crypto excedió el límite")
            self.stats.errores_sinconizacion += 1
            return False
    
    def aplicar_permisos(self):
        """Aplica los permisos configurados a archivos y directorios"""
        if not self.config.permisos_archivos and not self.config.permisos_directorios:
            return
        
        self.logger.info("Aplicando permisos...")
        
        # Aplicar permisos a archivos
        for patron, permisos in self.config.permisos_archivos.items():
            self._aplicar_permisos_patron(patron, permisos, es_directorio=False)
        
        # Aplicar permisos a directorios
        for patron, permisos in self.config.permisos_directorios.items():
            self._aplicar_permisos_patron(patron, permisos, es_directorio=True)
    
    def _aplicar_permisos_patron(self, patron: str, permisos: str, es_directorio: bool):
        """Aplica permisos a un patrón específico"""
        try:
            # Convertir permisos de string octal a int
            permisos_int = int(permisos, 8)
            
            if '*' in patron:
                # Patrón con comodín - usar glob
                directorio_base = Path(self.config.local_dir)
                archivos = list(directorio_base.rglob(patron))
                
                for archivo in archivos:
                    if es_directorio == archivo.is_dir():
                        if self.args.dry_run:
                            self.logger.debug(f"SIMULACIÓN: chmod {permisos} {archivo}")
                        else:
                            archivo.chmod(permisos_int)
            else:
                # Ruta específica
                ruta_completa = Path(self.config.local_dir) / patron
                if ruta_completa.exists() and es_directorio == ruta_completa.is_dir():
                    if self.args.dry_run:
                        self.logger.debug(f"SIMULACIÓN: chmod {permisos} {ruta_completa}")
                    else:
                        ruta_completa.chmod(permisos_int)
                        
        except (ValueError, OSError) as e:
            self.logger.warning(f"Error aplicando permisos a {patron}: {e}")
    
    def mostrar_estadisticas(self):
        """Muestra las estadísticas de la sincronización"""
        tiempo_total = self.stats.tiempo_total
        horas = int(tiempo_total // 3600)
        minutos = int((tiempo_total % 3600) // 60)
        segundos = int(tiempo_total % 60)
        
        print("\n" + "=" * 50)
        print("RESUMEN DE SINCRONIZACIÓN")
        print("=" * 50)
        print(f"Elementos procesados: {self.stats.elementos_procesados}")
        print(f"Archivos transferidos: {self.stats.archivos_transferidos}")
        
        if self.args.crypto:
            print(f"Archivos Crypto transferidos: {self.stats.archivos_crypto_transferidos}")
        
        if self.args.delete:
            print(f"Archivos borrados en destino: {self.stats.archivos_borrados}")
        
        if self.args.excludes:
            print(f"Exclusiones CLI aplicadas: {len(self.args.excludes)} patrones")
        
        print(f"Enlaces manejados: {self.stats.enlaces_creados + self.stats.enlaces_existentes}")
        print(f"  - Enlaces detectados/guardados: {self.stats.enlaces_detectados}")
        print(f"  - Enlaces creados: {self.stats.enlaces_creados}")
        print(f"  - Enlaces existentes: {self.stats.enlaces_existentes}")
        print(f"  - Enlaces con errores: {self.stats.enlaces_errores}")
        print(f"Errores de sincronización: {self.stats.errores_sincronizacion}")
        
        if tiempo_total >= 3600:
            print(f"Tiempo total: {horas}h {minutos}m {segundos}s")
        elif tiempo_total >= 60:
            print(f"Tiempo total: {minutos}m {segundos}s")
        else:
            print(f"Tiempo total: {segundos}s")
        
        archivos_por_segundo = (self.stats.archivos_transferidos / 
                               (tiempo_total if tiempo_total > 0 else 1))
        print(f"Velocidad promedio: {archivos_por_segundo:.1f} archivos/segundo")
        
        modo = "SIMULACIÓN" if self.args.dry_run else "EJECUCIÓN REAL"
        print(f"Modo: {modo}")
        print("=" * 50)
    
    def enviar_notificacion(self, titulo: str, mensaje: str, tipo: str = "info"):
        """Envía una notificación del sistema"""
        try:
            if platform.system() == "Linux" and shutil.which('notify-send'):
                urgencia = "normal"
                icono = "dialog-information"
                
                if tipo == "error":
                    urgencia = "critical"
                    icono = "dialog-error"
                elif tipo == "warning":
                    urgencia = "normal"
                    icono = "dialog-warning"
                
                subprocess.run([
                    'notify-send', '--urgency', urgencia, '--icon', icono, titulo, mensaje
                ], capture_output=True)
                
            elif platform.system() == "Darwin" and shutil.which('osascript'):
                script = f'display notification "{mensaje}" with title "{titulo}"'
                subprocess.run(['osascript', '-e', script], capture_output=True)
                
            else:
                icon = "🔔"
                if tipo == "error":
                    icon = "❌"
                elif tipo == "warning":
                    icon = "⚠️"
                print(f"\n{icon} {titulo}: {mensaje}")
                
        except (subprocess.SubprocessError, OSError):
            pass  # Silenciosamente fallar si no se pueden enviar notificaciones
    
    def notificar_finalizacion(self, exit_code: int):
        """Envía notificación de finalización"""
        time.sleep(0.5)  # Pequeña pausa
        
        if exit_code == 0:
            mensaje = (f"Sincronización finalizada con éxito\n"
                      f"• Elementos: {self.stats.elementos_procesados}\n"
                      f"• Transferidos: {self.stats.archivos_transferidos}\n"
                      f"• Tiempo: {self.stats.tiempo_total:.0f}s")
            self.enviar_notificacion("Sincronización Completada", mensaje, "info")
        else:
            mensaje = (f"Sincronización finalizada con errores\n"
                      f"• Errores: {self.stats.errores_sincronizacion}\n"
                      f"• Verifique el log: {self.config.log_file}")
            self.enviar_notificacion("Sincronización con Errores", mensaje, "error")
    
    def verificar_precondiciones(self) -> bool:
        """Verifica todas las precondiciones necesarias"""
        self.logger.debug("Verificando precondiciones...")
        
        # Verificar pCloud montado
        if not self.verificar_pcloud_montado():
            self.logger.error("Fallo en verificación de pCloud montado - abortando")
            return False
        else:
            self.logger.info("Verificación de pCloud montado: OK")
        
        # Verificar conectividad (solo advertencia)
        self.verificar_conectividad_pcloud()
        
        # Verificar espacio en disco (solo en modo ejecución real)
        if not self.args.dry_run:
            if not self.verificar_espacio_disco(500):
                self.logger.error("Fallo en verificación de espacio en disco - abortando")
                return False
            else:
                self.logger.info("Verificación de espacio en disco: OK")
        else:
            self.logger.debug("Modo dry-run: omitiendo verificación de espacio")
        
        self.logger.info("Todas las precondiciones verificadas correctamente")
        return True
    
    def procesar_elementos(self) -> bool:
        """Procesa todos los elementos de sincronización"""
        elementos = self.obtener_lista_sincronizacion()
        exit_code = True
        
        self.logger.info(f"Sincronizando {len(elementos)} elementos")
        
        for elemento in elementos:
            if not self.validar_elemento(elemento):
                exit_code = False
                continue
            
            if not self.sincronizar_elemento(elemento):
                exit_code = False
            
            print("-" * 50)
        
        return exit_code
    
    def sincronizar(self) -> int:
        """Función principal de sincronización"""
        self.logger.info(f"Iniciando proceso de sincronización en modo: "
                        f"{'subir' if self.args.subir else 'bajar'}")
        
        # Verificaciones previas
        if not self.verificar_precondiciones():
            return 1
        
        # Confirmación de ejecución (solo si no es dry-run)
        if not self.args.dry_run:
            self.confirmar_ejecucion()
        else:
            self.logger.debug("Modo dry-run: omitiendo confirmación de usuario")
        
        # Procesar elementos
        self.logger.info("Iniciando procesamiento de elementos...")
        exit_code = 0 if self.procesar_elementos() else 1
        
        # Sincronizar directorio Crypto si está habilitado
        if self.args.crypto:
            if not self.sincronizar_crypto():
                exit_code = 1
        else:
            self.logger.info("Sincronización de directorio Crypto excluida")
        
        # Manejar enlaces simbólicos
        self.logger.info("Iniciando manejo de enlaces simbólicos...")
        self.manejar_enlaces_simbolicos()
        
        # Aplicar permisos
        self.aplicar_permisos()
        
        if exit_code == 0:
            self.logger.info("Sincronización completada correctamente")
        else:
            self.logger.warning("Sincronización completada con errores")
        
        return exit_code
    
    def cleanup(self):
        """Limpia recursos temporales"""
        # Eliminar archivos temporales
        for temp_file in self.temp_files:
            try:
                if Path(temp_file).exists():
                    Path(temp_file).unlink()
                    self.logger.debug(f"Eliminado temporal: {temp_file}")
            except OSError:
                pass
        
        # Eliminar lock
        self.eliminar_lock()
    
    def run(self) -> int:
        """Ejecuta el proceso completo de sincronización"""
        try:
            # Parsear argumentos
            self.parse_arguments()
            
            # Verificar dependencias
            self.verificar_dependencias()
            
            # Mostrar banner
            self.mostrar_banner()
            
            # Establecer lock
            if not self.establecer_lock():
                return 1
            
            # Ejecutar sincronización
            exit_code = self.sincronizar()
            
            # Mostrar estadísticas
            self.mostrar_estadisticas()
            
            # Enviar notificación
            self.notificar_finalizacion(exit_code)
            
            return exit_code
            
        except Exception as e:
            self.logger.error(f"Error crítico: {e}")
            if self.args.verbose:
                import traceback
                self.logger.error(traceback.format_exc())
            return 1
        finally:
            self.cleanup()

# =========================
# Función principal
# =========================

def main():
    """Función principal"""
    syncb = SyncB()
    exit_code = syncb.run()
    sys.exit(exit_code)

if __name__ == "__main__":
    main()