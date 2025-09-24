#!/usr/bin/env python3
"""
Script de sincronización bidireccional entre directorio local y pCloud

Este script permite sincronizar archivos y directorios entre un directorio local
y pCloud en ambas direcciones (subir y bajar). Toda la configuración se carga desde
un archivo TOML único.

Uso:
    Para subir: python syncb.py --subir [opciones]
    Para bajar: python syncb.py --bajar [opciones]

TAREAS PENDIENTES:
- en que funcion crea (reconstruye lo enlaces simpolicos cuando) hacemos una bajada desde el fichero meta
- mas mensajes de informacion y de debug 
- Mayor portabilidad (Bash tiene más compatibilidad con diferentes sistemas)
- El archivo meta se genera correctamente durante la subida
- Los enlaces se recrean apropiadamente durante la bajada
- Los paths se normalizan correctamente entre diferentes sistemas
- actualizar documentacion readme con nuevas caracteristicas
- Mantén la versión Bash como principal por ahora, ya que está más completa y probada
- Implementa las funcionalidades faltantes en Python gradualmente
- Añade tests para verificar que ambas versiones se comportan igual
- Documenta las diferencias entre ambas implementaciones
- La versión Python tiene potencial a largo plazo por ser más mantenible, pero necesita alcanzar la paridad de funcionalidades con la versión Bash.
"""

import os
import sys
import argparse
import logging
import subprocess
import shutil
import tempfile
import atexit
import time
import datetime
import json
import signal
import platform
import psutil
from pathlib import Path
from typing import List, Dict, Tuple, Optional, Set, Any
from logging.handlers import RotatingFileHandler


try:
    import tomllib
except ImportError:
    # Para Python < 3.11, usar tomli
    try:
        import tomli as tomllib
    except ImportError:
        print("ERROR: Se requiere tomli para Python < 3.11")
        print("Instalar con: pip install tomli")
        sys.exit(1)


class Config:
    """Carga y gestiona la configuración desde un archivo TOML"""
    
    # Ubicaciones por defecto para buscar el archivo de configuración
    DEFAULT_CONFIG_SEARCH_PATHS = [
        "syncb_config.toml",
        "~/.config/syncb/syncb_config.toml",
        "/etc/syncb/syncb_config.toml"
    ]
    
    def __init__(self, config_file=None):
        # Ruta para el archivo de configuración
        self.config_file = config_file or self._find_config_file()
        
        if not self.config_file or not self.config_file.exists():
            raise FileNotFoundError(f"No se encontró el archivo de configuración: {config_file}")
        
        # Cargar configuración
        self.config_data = self._load_config()
        
        # Asignar valores de configuración
        self._assign_config_values()
    
    def _find_config_file(self):
        """Busca el archivo de configuración en ubicaciones configurables"""
        # Primero intentar con las ubicaciones por defecto
        search_paths = self.DEFAULT_CONFIG_SEARCH_PATHS.copy()
        
        for location in search_paths:
            # Expandir ~ y variables de entorno
            expanded_location = Path(os.path.expanduser(os.path.expandvars(location)))
            if expanded_location.exists():
                return expanded_location
        
        return None
    
    def _load_config(self):
        """Carga la configuración desde el archivo TOML"""
        try:
            with open(self.config_file, 'rb') as f:
                return tomllib.load(f)
        except Exception as e:
            raise RuntimeError(f"Error cargando configuración: {e}")
            
    def _parse_ansi_escape(self, color_str):
        """Convierte una cadena con escapes ANSI en la secuencia de escape real"""
        return color_str.encode().decode('unicode_escape')   
            
    def _assign_config_values(self):
        """Asigna valores de configuración a atributos de clase"""
        # Rutas y directorios
        paths = self.config_data.get('paths', {})
        self.LOCAL_DIR = Path(os.path.expanduser(os.path.expandvars(paths.get('local_dir', "~"))))
        self.PCLOUD_MOUNT_POINT = Path(os.path.expanduser(os.path.expandvars(paths.get('pcloud_mount_point', "~/pCloudDrive"))))
        self.PCLOUD_BACKUP_COMUN = self.PCLOUD_MOUNT_POINT / Path(os.path.expanduser(os.path.expandvars(
            paths.get('pcloud_backup_comun', str(self.PCLOUD_MOUNT_POINT / "Backups" / "Backup_Comun")))))
        self.PCLOUD_BACKUP_READONLY = self.PCLOUD_MOUNT_POINT / Path(os.path.expanduser(os.path.expandvars(
            paths.get('pcloud_backup_readonly', str(self.PCLOUD_MOUNT_POINT / "pCloud Backup" / "feynman.sobremesa.dnf")))))
                
        # Variables de configuración crypto (NUEVO)
        crypto = self.config_data.get('crypto', {})
        self.LOCAL_CRYPTO_DIR = Path(os.path.expanduser(os.path.expandvars(
            crypto.get('local_crypto_dir', "~/Crypto"))))
        self.REMOTO_CRYPTO_DIR = Path(os.path.expanduser(os.path.expandvars(
            crypto.get('remote_crypto_dir', "~/pCloudDrive/Crypto Folder"))))
        self.CLOUD_MOUNT_CHECK_FILE = crypto.get('cloud_mount_check_file', "mount.check")
        self.CLOUD_MOUNT_CHECK = self.REMOTO_CRYPTO_DIR / self.CLOUD_MOUNT_CHECK_FILE
        self.LOCAL_KEEPASS_DIR = Path(os.path.expanduser(os.path.expandvars(
            crypto.get('local_keepass_dir', str(self.LOCAL_CRYPTO_DIR / "ficheros_sensibles" / "Keepass2Android")))))
        self.REMOTE_KEEPASS_DIR = Path(os.path.expanduser(os.path.expandvars(
            crypto.get('remote_keepass_dir', "~/pCloudDrive/Applications/Keepass2Android"))))
        self.LOCAL_CRYPTO_HOSTNAME_RTVA_DIR = Path(os.path.expanduser(os.path.expandvars(
            crypto.get('local_crypto_hostname_rtva_dir', str(self.LOCAL_CRYPTO_DIR / "ficheros_sensibles")))))
        self.REMOTO_CRYPTO_HOSTNAME_RTVA_DIR = Path(os.path.expanduser(os.path.expandvars(
            crypto.get('remote_crypto_hostname_rtva_dir', str(self.REMOTO_CRYPTO_DIR / "ficheros_sensibles")))))
                
        # Ubicaciones de búsqueda de configuración
        self.CONFIG_SEARCH_PATHS = [
            os.path.expanduser(os.path.expandvars(path))
            for path in paths.get('config_search_paths', self.DEFAULT_CONFIG_SEARCH_PATHS)
        ]
        
        # Archivos
        files = self.config_data.get('files', {})
        self.LISTA_POR_DEFECTO_FILE = files.get('lista_por_defecto', "syncb_config.toml")
        self.LISTA_ESPECIFICA_POR_DEFECTO_FILE = files.get('lista_especifica_por_defecto', "syncb_config.toml")
        self.EXCLUSIONES_FILE = files.get('exclusiones_file', "syncb_config.toml")
        self.SYMLINKS_FILE = files.get('symlinks_file', ".syncb_symlinks.meta")
        self.LOG_FILE = Path(os.path.expanduser(os.path.expandvars(files.get('log_file', "~/syncb.log"))))
        
        # Configuración general
        general = self.config_data.get('general', {})
        self.LOCK_TIMEOUT = general.get('lock_timeout', 3600)
        self.HOSTNAME_RTVA = general.get('hostname_rtva', "feynman.rtva.dnf")
        self.DEFAULT_TIMEOUT_MINUTES = general.get('default_timeout_minutes', 30)
        
        # Listas de sincronización y exclusión (directamente desde TOML) (en la seccion general)
        self.directorios_sincronizacion = general.get('directorios_sincronizacion', [])
        self.exclusiones = general.get('exclusiones', [])

        # Permisos permisos_ejecutables
        permisos_ejecutables = self.config_data.get('permisos_ejecutables', {})
        self.PERMISOS_FILES = permisos_ejecutables.get('archivos', [])
        
        # Logging (para log rotativos)
        logging_config = self.config_data.get('logging', {})
        self.LOG_MAX_SIZE_MB = logging_config.get('max_size_mb', 10)
        self.LOG_BACKUP_COUNT = logging_config.get('backup_count', 5)

        # Configuración de notificaciones
        notifications = self.config_data.get('notifications', {})
        self.NOTIFICATIONS_ENABLED = notifications.get('enabled', True)
    
        # Colores para logging (códigos ANSI)
        colors = self.config_data.get('colors', {})
        # Procesar cada color para interpretar las secuencias de escape
        self.RED = self._parse_ansi_escape(colors.get('red', '\033[0;31m'))
        self.GREEN = self._parse_ansi_escape(colors.get('green', '\033[0;32m'))
        self.YELLOW = self._parse_ansi_escape(colors.get('yellow', '\033[1;33m'))
        self.BLUE = self._parse_ansi_escape(colors.get('blue', '\033[0;34m'))
        self.MAGENTA = self._parse_ansi_escape(colors.get('magenta', '\033[0;35m'))
        self.CYAN = self._parse_ansi_escape(colors.get('cyan', '\033[0;36m'))
        self.WHITE = self._parse_ansi_escape(colors.get('white', '\033[1;37m'))
        self.NC = self._parse_ansi_escape(colors.get('no_color', '\033[0m'))  # No Color
        
        # Iconos Unicode
        icons = self.config_data.get('icons', {})
        self.CHECK_MARK = icons.get('check_mark', "✓")
        self.CROSS_MARK = icons.get('cross_mark', "✗")
        self.INFO_ICON = icons.get('info_icon', "ℹ")
        self.WARNING_ICON = icons.get('warning_icon', "⚠")
        self.CLOCK_ICON = icons.get('clock_icon', "⏱")
        self.SYNC_ICON = icons.get('sync_icon', "🔄")
        self.ERROR_ICON = icons.get('error_icon', "❌")
        self.SUCCESS_ICON = icons.get('success_icon', "✅")
        
     
class SyncBidireccional:
    """Clase principal para la sincronización bidireccional"""
    
    def __init__(self, config_file=None):
        """Inicializa la instancia con valores por defecto"""
        try:
            self.config = Config(config_file)
        except Exception as e:
            print(f"Error cargando configuración: {e}")
            # Intentar cargar con ubicaciones por defecto
            try:
                self.config = Config()
            except Exception:
                print("No se pudo cargar la configuración. Saliendo.")
                sys.exit(1)
            
        self.modo = None  # 'subir' o 'bajar'
        self.dry_run = False
        self.delete = False
        self.yes = False
        self.overwrite = False
        self.backup_dir_mode = "comun"  # 'comun' o 'readonly'
        self.verbose = False
        self.use_checksum = False
        self.bw_limit = None
        self.timeout_minutes = self.config.DEFAULT_TIMEOUT_MINUTES
        self.items_especificos = []
        self.exclusiones_cli = []
        self.sync_crypto = False  # NUEVO: Control de sincronización Crypto
        
        # Variables para estadísticas
        self.elementos_procesados = 0
        self.errores_sincronizacion = 0
        self.archivos_transferidos = 0
        self.enlaces_creados = 0
        self.enlaces_existentes = 0
        self.enlaces_errores = 0
        self.enlaces_detectados = 0
        self.archivos_borrados = 0
        self.archivos_crypto_transferidos = 0  # NUEVO: Contador para archivos Crypto
        
        # Tiempo de inicio
        self.start_time = time.time()
        
        # Obtener hostname
        self.hostname = platform.node()
        
        # Determinar el directorio del script
        self.script_dir = Path(__file__).parent.absolute()
        
        # Configurar logging
        self.setup_logging()
        
        # Comprobar rotación de logs
        self.check_log_rotation()        
                
        # Lista para tracking de archivos temporales
        self.temp_files = []
        self.temp_dirs = []
        
        # Registrar cleanup al salir
        atexit.register(self.cleanup_temporales)    
        
        # Lock file
        self.LOCK_FILE = Path(tempfile.gettempdir()) / "syncb.lock"        

    def crear_temp_file(self, suffix='', prefix='syncb_', mode='w+b'):
        """
        Crea un archivo temporal y lo registra para cleanup automático
        
        Args:
            suffix (str): Sufijo del archivo temporal
            prefix (str): Prefijo del archivo temporal
            mode (str): Modo de apertura del archivo
            
        Returns:
            tempfile.NamedTemporaryFile: Objeto de archivo temporal
        """
        try:
            temp_file = tempfile.NamedTemporaryFile(
                mode=mode, 
                suffix=suffix, 
                prefix=prefix,
                delete=False  # No eliminar automáticamente al cerrar
            )
            self.temp_files.append(temp_file.name)
            self.log_debug(f"Archivo temporal creado: {temp_file.name}")
            return temp_file
        except Exception as e:
            self.log_error(f"Error creando archivo temporal: {e}")
            raise
    
    def crear_temp_dir(self, suffix='', prefix='syncb_'):
        """
        Crea un directorio temporal y lo registra para cleanup automático
        
        Args:
            suffix (str): Sufijo del directorio temporal
            prefix (str): Prefijo del directorio temporal
            
        Returns:
            str: Ruta al directorio temporal creado
        """
        try:
            temp_dir = tempfile.mkdtemp(suffix=suffix, prefix=prefix)
            self.temp_dirs.append(temp_dir)
            self.log_debug(f"Directorio temporal creado: {temp_dir}")
            return temp_dir
        except Exception as e:
            self.log_error(f"Error creando directorio temporal: {e}")
            raise
    
    def cleanup_temporales(self):
        """
        Elimina todos los archivos y directorios temporales registrados
        """
        deleted_files = 0
        deleted_dirs = 0
        
        # Eliminar archivos temporales
        for temp_file in self.temp_files[:]:
            try:
                if os.path.exists(temp_file):
                    os.unlink(temp_file)
                    deleted_files += 1
                    self.log_debug(f"Archivo temporal eliminado: {temp_file}")
                self.temp_files.remove(temp_file)
            except Exception as e:
                self.log_error(f"Error eliminando archivo temporal {temp_file}: {e}")
        
        # Eliminar directorios temporales
        for temp_dir in self.temp_dirs[:]:
            try:
                if os.path.exists(temp_dir):
                    shutil.rmtree(temp_dir)
                    deleted_dirs += 1
                    self.log_debug(f"Directorio temporal eliminado: {temp_dir}")
                self.temp_dirs.remove(temp_dir)
            except Exception as e:
                self.log_error(f"Error eliminando directorio temporal {temp_dir}: {e}")
        
        if deleted_files > 0 or deleted_dirs > 0:
            self.log_info(f"Cleanup completado: {deleted_files} archivos y {deleted_dirs} directorios temporales eliminados")
    
    def registrar_temp_file(self, file_path):
        """
        Registra un archivo existente para cleanup automático
        
        Args:
            file_path (str): Ruta al archivo a registrar
        """
        if os.path.exists(file_path):
            self.temp_files.append(file_path)
            self.log_debug(f"Archivo registrado para cleanup: {file_path}")
    
    def registrar_temp_dir(self, dir_path):
        """
        Registra un directorio existente para cleanup automático
        
        Args:
            dir_path (str): Ruta al directorio a registrar
        """
        if os.path.exists(dir_path):
            self.temp_dirs.append(dir_path)
            self.log_debug(f"Directorio registrado para cleanup: {dir_path}")
    
    def manejo_temporal_context(self):
        """
        Context manager para manejo automático de temporales
        """
        class TemporalContext:
            def __init__(self, parent):
                self.parent = parent
                self.files = []
                self.dirs = []
            
            def __enter__(self):
                return self
            
            def temp_file(self, *args, **kwargs):
                file_obj = self.parent.crear_temp_file(*args, **kwargs)
                self.files.append(file_obj.name)
                return file_obj
            
            def temp_dir(self, *args, **kwargs):
                dir_path = self.parent.crear_temp_dir(*args, **kwargs)
                self.dirs.append(dir_path)
                return dir_path
            
            def __exit__(self, exc_type, exc_val, exc_tb):
                # Cleanup de los temporales creados en este contexto
                for file_path in self.files:
                    if file_path in self.parent.temp_files:
                        self.parent.temp_files.remove(file_path)
                        try:
                            if os.path.exists(file_path):
                                os.unlink(file_path)
                        except:
                            pass
                
                for dir_path in self.dirs:
                    if dir_path in self.parent.temp_dirs:
                        self.parent.temp_dirs.remove(dir_path)
                        try:
                            if os.path.exists(dir_path):
                                shutil.rmtree(dir_path)
                        except:
                            pass
        
        return TemporalContext(self)

    def setup_logging(self):
        """Configura el sistema de logging"""
        # Crear formateador personalizado con colores
        class ColoredFormatter(logging.Formatter):
            """Formateador de log con colores"""
            
            def __init__(self, config):
                self.config = config
                super().__init__()
            
            def format(self, record):
                # Formato con colores ANSI
                if record.levelno == logging.DEBUG:
                    return f"{self.config.MAGENTA}{self.config.CLOCK_ICON} [DEBUG]{self.config.NC} {record.getMessage()}"
                elif record.levelno == logging.INFO:
                    return f"{self.config.BLUE}{self.config.INFO_ICON} [INFO]{self.config.NC} {record.getMessage()}"
                elif record.levelno == logging.WARNING:
                    return f"{self.config.YELLOW}{self.config.WARNING_ICON} [WARN]{self.config.NC} {record.getMessage()}"
                elif record.levelno == logging.ERROR:
                    return f"{self.config.RED}{self.config.CROSS_MARK} [ERROR]{self.config.NC} {record.getMessage()}"
                elif record.levelno == logging.CRITICAL:
                    return f"{self.config.RED}{self.config.ERROR_ICON} [CRITICAL]{self.config.NC} {record.getMessage()}"
                else:
                    return f"{record.getMessage()}"
        
        # Configurar logger principal
        self.logger = logging.getLogger('syncb')
        self.logger.setLevel(logging.DEBUG)
        
        # Handler para consola
        console_handler = logging.StreamHandler()
        console_handler.setLevel(logging.DEBUG)
        console_handler.setFormatter(ColoredFormatter(self.config))
        self.logger.addHandler(console_handler)
        
        # Configurar rotación: 10MB por archivo, mantener 5 backups        
        max_bytes = self.config.LOG_MAX_SIZE_MB * 1024 * 1024
        backup_count = self.config.LOG_BACKUP_COUNT # Mantener 5 archivos de backup

        # Handler para archivo (sin colores) con rotacion 
        file_handler = RotatingFileHandler(
            self.config.LOG_FILE, 
            maxBytes=max_bytes, 
            backupCount=backup_count,
            encoding='utf-8'
        )
        file_handler.setLevel(logging.INFO)
        file_formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
        file_handler.setFormatter(file_formatter)
        self.logger.addHandler(file_handler)
        
    def log_info(self, msg):
        """Registra un mensaje informativo"""
        self.logger.info(msg)
    
    def log_warn(self, msg):
        """Registra un mensaje de advertencia"""
        self.logger.warning(msg)
    
    def log_error(self, msg):
        """Registra un mensaje de error"""
        self.logger.error(msg)
    
    def log_debug(self, msg):
        """Registra un mensaje de debug"""
        if self.verbose:
            self.logger.debug(msg)
    
    def log_success(self, msg):
        """Registra un mensaje de éxito"""
        self.logger.info(f"{self.config.GREEN}{self.config.CHECK_MARK} [SUCCESS]{self.config.NC} {msg}")
    
    def parse_arguments(self):
        """Procesa los argumentos de línea de comandos"""
        parser = argparse.ArgumentParser(
            description="Sincronización bidireccional entre directorio local y pCloud",
            epilog="Ejemplos:\n"
                   "  syncb.py --subir\n"
                   "  syncb.py --bajar --dry-run\n"
                   "  syncb.py --subir --delete --yes\n"
                   "  syncb.py --subir --item documentos/\n"
                   "  syncb.py --bajar --item configuracion.ini --item .local/bin --dry-run\n"
                   "  syncb.py --subir --crypto  # NUEVO: incluir directorio Crypto",
            formatter_class=argparse.RawTextHelpFormatter
        )
        
        # Opciones principales
        group = parser.add_mutually_exclusive_group(required=True)
        group.add_argument("--subir", action="store_true", help="Sincroniza desde local a pCloud")
        group.add_argument("--bajar", action="store_true", help="Sincroniza desde pCloud a local")
        
        # Opciones secundarias
        parser.add_argument("--delete", action="store_true", help="Elimina archivos obsoletos en destino")
        parser.add_argument("--dry-run", action="store_true", help="Simula sin hacer cambios reales")
        parser.add_argument("--item", action="append", help="Sincroniza solo el elemento especificado")
        parser.add_argument("--exclude", action="append", help="Excluye archivos que coincidan con el patrón")
        parser.add_argument("--yes", action="store_true", help="Ejecuta sin confirmación")
        parser.add_argument("--backup-dir", action="store_true", help="Usa directorio de backup de solo lectura")
        parser.add_argument("--overwrite", action="store_true", help="Sobrescribe todos los archivos en destino")
        parser.add_argument("--checksum", action="store_true", help="Fuerza comparación con checksum")
        parser.add_argument("--bwlimit", type=int, help="Limita la velocidad de transferencia (KB/s)")
        parser.add_argument("--timeout", type=int, default=30, help="Límite de tiempo por operación (minutos)")
        parser.add_argument("--force-unlock", action="store_true", help="Fuerza eliminación de lock")
        parser.add_argument("--crypto", action="store_true", help="Incluye la sincronización del directorio Crypto")  # NUEVO
        parser.add_argument("--verbose", action="store_true", help="Habilita modo verboso")
        parser.add_argument("--test", action="store_true", help="Ejecuta tests unitarios")
        parser.add_argument("--config", type=str, help="Ruta al archivo de configuración TOML")
        
        args = parser.parse_args()
        
        # Asignar valores
        if args.subir:
            self.modo = "subir"
        elif args.bajar:
            self.modo = "bajar"
        
        self.dry_run = args.dry_run
        self.delete = args.delete
        self.yes = args.yes
        self.overwrite = args.overwrite
        self.use_checksum = args.checksum
        self.bw_limit = args.bwlimit
        self.timeout_minutes = args.timeout
        self.verbose = args.verbose
        self.sync_crypto = args.crypto  # NUEVO
        
        if args.item:
            self.items_especificos = args.item
        
        if args.exclude:
            self.exclusiones_cli = args.exclude
        
        if args.backup_dir:
            self.backup_dir_mode = "readonly"
        
        # Manejar opciones especiales
        if args.force_unlock:
            self.force_unlock()
            sys.exit(0)
        
        if args.test:
            self.run_tests()
            sys.exit(0)
            
        # Si se especificó un archivo de configuración, recargar configuración
        if args.config:
            try:
                self.config = Config(Path(args.config))
            except Exception as e:
                self.log_error(f"No se pudo cargar la configuración desde {args.config}: {e}")
                sys.exit(1)
    
    def force_unlock(self):
        """Fuerza la eliminación del archivo de lock"""
        if self.LOCK_FILE.exists():
            self.LOCK_FILE.unlink()
            self.log_info("Lock eliminado forzosamente")
        else:
            self.log_info("No existe archivo de lock")
    
    def get_pcloud_dir(self):
        """Obtiene el directorio de pCloud según el modo"""
        if self.backup_dir_mode == "readonly":
            return self.config.PCLOUD_BACKUP_READONLY
        else:
            return self.config.PCLOUD_BACKUP_COMUN
   
    # ERROR, no funciona se emplea la funcion de abajo
    def get_lista_sincronizacion1(self):
        """Obtiene la lista de elementos a sincronizar"""
        # Si hay elementos específicos desde CLI, usarlos
        if self.items_especificos:
            return self.items_especificos
            
        # Si el hostname es el de RTVA, buscar lista específica
        if self.hostname == self.config.HOSTNAME_RTVA:
            # Buscar lista específica en la configuración
            host_specific = self.config.config_data.get('host_specific', {})
            # Usar el hostname con puntos entre comillas
            host_key = f'"{self.hostname}"' if '.' in self.hostname else self.hostname
            if host_key in host_specific:
                return host_specific[host_key].get('directorios_sincronizacion', [])
        
        # Devolver lista por defecto de la configuración
        return self.config.directorios_sincronizacion
   
    def get_lista_sincronizacion(self):
        """Obtiene la lista de elementos a sincronizar"""
        # Si hay elementos específicos desde CLI, usarlos
        if self.items_especificos:
            return self.items_especificos
            
        # Si el hostname es el de RTVA, buscar lista específica
        if self.hostname == self.config.HOSTNAME_RTVA:
            # Buscar lista específica en la configuración
            if 'host_specific' in self.config.config_data and self.hostname in self.config.config_data['host_specific']:
                return self.config.config_data['host_specific'][self.hostname].get('directorios_sincronizacion', [])

        # Devolver lista por defecto de la configuración
        return self.config.directorios_sincronizacion

    def get_exclusiones(self):
        """Obtiene la lista de exclusiones"""
        exclusiones = self.config.exclusiones.copy()
        exclusiones.extend(self.exclusiones_cli)
        return exclusiones
    
    def verificar_pcloud_montado(self):
        """Verifica que pCloud esté montado correctamente con comprobaciones robustas"""
        pcloud_dir = self.get_pcloud_dir()
        
        # 1. Verificar si el punto de montaje existe
        if not self.config.PCLOUD_MOUNT_POINT.exists():
            self.log_error(f"El punto de montaje de pCloud no existe: {self.config.PCLOUD_MOUNT_POINT}")
            self.log_info("Asegúrate de que pCloud Drive esté instalado y ejecutándose.")
            return False
        
        # 2. Verificar si el directorio está vacío (puede indicar que no está montado)
        try:
            if not any(self.config.PCLOUD_MOUNT_POINT.iterdir()):
                self.log_error(f"El directorio de pCloud está vacío: {self.config.PCLOUD_MOUNT_POINT}")
                self.log_info("Esto sugiere que pCloud Drive no está montado correctamente.")
                return False
        except PermissionError:
            self.log_error(f"Sin permisos para acceder al directorio: {self.config.PCLOUD_MOUNT_POINT}")
            return False
        
        # 3. Verificar montaje de la carpeta Crypto si está habilitado (NUEVO)
        if self.sync_crypto:
            self.log_debug(f"Verificando montaje de Crypto en: {self.config.REMOTO_CRYPTO_DIR}")
            if not self.config.CLOUD_MOUNT_CHECK.exists():
                self.log_error("El volumen Crypto no está montado o el archivo de verificación no existe")
                self.log_error(f"Por favor, desbloquea/monta la unidad en: \"{self.config.REMOTO_CRYPTO_DIR}\"")
                return False
        
        # 4. Verificación robusta usando diferentes métodos según el sistema operativo
        sistema = platform.system()
        montado = False
        
        try:
            if sistema == "Linux":
                # Método 1: Usar findmnt (más preciso)
                try:
                    result = subprocess.run(["findmnt", "-rno", "TARGET", str(self.config.PCLOUD_MOUNT_POINT)], 
                                          capture_output=True, text=True, timeout=5)
                    montado = result.returncode == 0
                except (subprocess.TimeoutExpired, FileNotFoundError):
                    # Método 2: Verificar /proc/mounts
                    with open('/proc/mounts', 'r') as f:
                        mounts = f.read()
                    montado = str(self.config.PCLOUD_MOUNT_POINT) in mounts
                
                # Método 3: Usar mountpoint
                if not montado:
                    try:
                        result = subprocess.run(["mountpoint", "-q", str(self.config.PCLOUD_MOUNT_POINT)], 
                                              timeout=5, check=False)
                        montado = result.returncode == 0
                    except (subprocess.TimeoutExpired, FileNotFoundError):
                        pass
            
            elif sistema == "Darwin":  # macOS
                # Método: Usar mount y buscar el punto de montaje
                result = subprocess.run(["mount"], capture_output=True, text=True, timeout=5)
                montado = str(self.config.PCLOUD_MOUNT_POINT) in result.stdout
            
            else:
                # Para otros sistemas, usar una verificación genérica
                self.log_warn(f"Sistema operativo {sistema} no específicamente soportado")
                
                # Intentar verificar con df
                try:
                    result = subprocess.run(["df", str(self.config.PCLOUD_MOUNT_POINT)], 
                                          capture_output=True, text=True, timeout=5)
                    montado = result.returncode == 0
                except (subprocess.TimeoutExpired, FileNotFoundError):
                    # Último recurso: verificar si podemos acceder al directorio
                    try:
                        montado = os.access(str(self.config.PCLOUD_MOUNT_POINT), os.R_OK)
                    except:
                        montado = False
            
            if not montado:
                self.log_error(f"pCloud no aparece montado en {self.config.PCLOUD_MOUNT_POINT}")
                return False
        
        except Exception as e:
            self.log_error(f"Error verificando montaje: {e}")
            # Continuar con otras verificaciones a pesar del error
        
        # 5. Verificar si el directorio específico de pCloud existe
        if not pcloud_dir.exists():
            self.log_error(f"El directorio de pCloud no existe: {pcloud_dir}")
            self.log_info("Asegúrate de que:")
            self.log_info("1. pCloud Drive esté ejecutándose")
            self.log_info("2. Tu cuenta de pCloud esté sincronizada")
            self.log_info("3. El directorio exista en tu pCloud")
            return False
        
        # 6. Verificar permisos de escritura (solo si no es dry-run y no es modo backup-dir)
        if not self.dry_run and self.backup_dir_mode == "comun":
            try:
                test_file = pcloud_dir / f".test_write_{os.getpid()}"
                test_file.touch()
                test_file.unlink()
            except Exception as e:
                self.log_error(f"No se puede escribir en: {pcloud_dir} - {e}")
                return False
        
        # 7. Verificación adicional: intentar listar contenido
        try:
            # Intentar listar algunos elementos del directorio
            list(pcloud_dir.iterdir())
        except Exception as e:
            self.log_error(f"Error accediendo al contenido de {pcloud_dir}: {e}")
            return False
        
        self.log_info("Verificación de pCloud: OK - El directorio está montado y accesible")
        return True
    
    def verificar_espacio_pcloud(self):
        """Verifica el espacio disponible en pCloud"""
        pcloud_dir = self.get_pcloud_dir()
        
        try:
            # Obtener uso de disco para el punto de montaje de pCloud
            usage = shutil.disk_usage(str(self.config.PCLOUD_MOUNT_POINT))
            libre_gb = usage.free / (1024**3)
            total_gb = usage.total / (1024**3)
            
            self.log_info(f"Espacio en pCloud: {libre_gb:.2f} GB libres de {total_gb:.2f} GB")
            
            # Advertencia si queda menos de 1GB
            if libre_gb < 1:
                self.log_warn("Queda menos de 1GB de espacio en pCloud")
                
            return libre_gb
        except Exception as e:
            self.log_error(f"Error verificando espacio en pCloud: {e}")
            return None

    def verificar_estado_pcloud(self):
        """Verifica el estado del cliente pCloud"""
        sistema = platform.system()
        
        try:
            if sistema == "Linux":
                # Verificar si el proceso pCloud está ejecutándose
                result = subprocess.run(["pgrep", "-x", "pcloud"], capture_output=True, text=True)
                if result.returncode == 0:
                    self.log_info("Cliente pCloud está ejecutándose")
                    return True
                else:
                    self.log_warn("Cliente pCloud no parece estar ejecutándose")
                    return False
            
            elif sistema == "Darwin":  # macOS
                # Verificar procesos en macOS
                result = subprocess.run(["pgrep", "-x", "pCloud"], capture_output=True, text=True)
                return result.returncode == 0
            
            elif sistema == "Windows":
                # Verificar procesos en Windows
                result = subprocess.run(["tasklist", "/fi", "IMAGENAME eq pcloud.exe"], capture_output=True, text=True)
                return "pcloud.exe" in result.stdout
            
            else:
                self.log_warn(f"No se puede verificar estado de pCloud en {sistema}")
                return None
                
        except Exception as e:
            self.log_error(f"Error verificando estado de pCloud: {e}")
            return None    
    
    def verificar_conectividad_pcloud(self):
        """Verifica la conectividad con pCloud"""
        self.log_debug("Verificando conectividad con pCloud...")
        
        try:
            # Intentamos hacer un ping a pCloud
            result = subprocess.run(["curl", "-s", "https://www.pcloud.com/"], capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                self.log_info("Verificación de conectividad pCloud: OK")
                return True
            else:
                self.log_warn("No se pudo conectar a pCloud. Verifica tu conexión a Internet.")
                return False
        except subprocess.TimeoutExpired:
            self.log_warn("Timeout al verificar conectividad con pCloud")
            return False
        except Exception as e:
            self.log_warn(f"Error al verificar conectividad con pCloud: {e}")
            return False
    
    def verificar_espacio_disco(self, mb_necesarios=100):
        """Verifica que haya suficiente espacio en disco"""
        pcloud_dir = self.get_pcloud_dir()
        
        # Determinar el directorio a verificar según el modo
        if self.modo == "subir":
            directorio = pcloud_dir
        else:
            directorio = self.config.LOCAL_DIR
            
        # Obtener el espacio libre en MB
        try:
            stat = shutil.disk_usage(directorio)
            libre_mb = stat.free / (1024 * 1024)
            if libre_mb < mb_necesarios:
                self.log_error(f"Espacio insuficiente en {directorio}. Libre: {libre_mb:.2f} MB, Necesario: {mb_necesarios} MB")
                return False
            else:
                self.log_info(f"Espacio en disco: {libre_mb:.2f} MB libres")
                return True
        except Exception as e:
            self.log_error(f"Error al verificar espacio en disco: {e}")
            return False
    
    def mostrar_banner(self):
        """Muestra el banner informativo"""
        pcloud_dir = self.get_pcloud_dir()
        
        print("=" * 50)
        if self.modo == "subir":
            print("MODO: SUBIR (Local → pCloud)")
            print(f"ORIGEN: {self.config.LOCAL_DIR}")
            print(f"DESTINO: {pcloud_dir}")
        else:
            print("MODO: BAJAR (pCloud → Local)")
            print(f"ORIGEN: {pcloud_dir}")
            print(f"DESTINO: {self.config.LOCAL_DIR}")
        
        if self.backup_dir_mode == "readonly":
            print("DIRECTORIO: Backup de solo lectura (pCloud Backup)")
        else:
            print("DIRECTORIO: Backup común (Backup_Comun)")
        
        if self.dry_run:
            print(f"ESTADO: {self.config.YELLOW}MODO SIMULACIÓN{self.config.NC} (no se realizarán cambios)")
        
        if self.delete:
            print(f"BORRADO: {self.config.GREEN}ACTIVADO{self.config.NC} (se eliminarán archivos obsoletos)")
        
        if self.yes:
            print("CONFIRMACIÓN: Automática (sin preguntar)")
        
        if self.overwrite:
            print(f"SOBRESCRITURA: {self.config.GREEN}ACTIVADA{self.config.NC}")
        else:
            print("MODO: SEGURO (--update activado)")
        
        # NUEVO: Información sobre Crypto
        if self.sync_crypto:
            print(f"CRYPTO: {self.config.GREEN}INCLUIDO{self.config.NC} (se sincronizará directorio Crypto)")
        else:
            print(f"CRYPTO: {self.config.YELLOW}EXCLUIDO{self.config.NC} (no se sincronizará directorio Crypto)")
        
        elementos = self.get_lista_sincronizacion()
        if self.items_especificos:
            print(f"ELEMENTOS ESPECÍFICOS: {', '.join(self.items_especificos)}")
        else:
            print(f"ELEMENTOS A SINCRONIZAR: {len(elementos)} elementos desde configuración")
            if self.verbose:
                for i, elemento in enumerate(elementos, 1):
                    print(f"  {i}. {elemento}")
        
        exclusiones = self.get_exclusiones()
        if exclusiones:
            print(f"EXCLUSIONES ({len(exclusiones)} patrones):")
            for i, patron in enumerate(exclusiones[:5], 1):  # Mostrar solo las primeras 5
                print(f"  {i}. {patron}")
            if len(exclusiones) > 5:
                print(f"  ... y {len(exclusiones) - 5} más")
        
        print(f"ARCHIVO DE CONFIGURACIÓN: {self.config.config_file}")
        print("=" * 50)
    
    def confirmar_ejecucion(self):
        """Solicita confirmación al usuario antes de ejecutar"""
        if self.yes:
            self.log_info("Confirmación automática (--yes): se procede con la sincronización")
            return
        
        if sys.stdin.isatty():  # Hay entrada interactiva disponible
            respuesta = input("¿Desea continuar con la sincronización? [s/N]: ")
            if respuesta.lower() not in ['s', 'si', 'sí', 'y', 'yes']:
                self.log_info("Operación cancelada por el usuario.")
                sys.exit(0)
        else:
            self.log_error("No hay entrada interactiva disponible (usa --yes)")
            sys.exit(1)
    
    def establecer_lock(self):
        """Establece un lock para evitar ejecuciones concurrentes"""
        if self.LOCK_FILE.exists():
            # Leer información del lock existente
            try:
                with open(self.LOCK_FILE, 'r') as f:
                    lock_info = json.load(f)
                
                lock_pid = lock_info.get('pid')
                lock_time = lock_info.get('timestamp', 0)
                current_time = time.time()
                lock_age = current_time - lock_time
                
                if lock_age > self.config.LOCK_TIMEOUT:
                    self.log_warn(f"Eliminando lock obsoleto (edad: {lock_age:.0f}s > timeout: {self.config.LOCK_TIMEOUT}s)")
                    self.LOCK_FILE.unlink()
                else:
                    # Verificar si el proceso todavía existe
                    try:
                        os.kill(lock_pid, 0)  # Verifica si el proceso existe
                        self.log_error(f"Ya hay una ejecución en progreso (PID: {lock_pid})")
                        self.log_error(f"Dueño del lock: PID {lock_pid}, Iniciado: {lock_info.get('start_time', 'desconocido')}")
                        return False
                    except OSError:
                        # El proceso ya no existe
                        self.log_warn(f"Eliminando lock obsoleto del proceso {lock_pid}")
                        self.LOCK_FILE.unlink()
            except (json.JSONDecodeError, IOError):
                # El archivo de lock está corrupto o no se puede leer
                self.log_warn("Eliminando lock corrupto")
                self.LOCK_FILE.unlink()
        
        # Crear nuevo lock
        lock_info = {
            'pid': os.getpid(),
            'timestamp': time.time(),
            'start_time': datetime.datetime.now().isoformat(),
            'modo': self.modo,
            'user': os.getlogin(),
            'hostname': self.hostname
        }
        
        try:
            with open(self.LOCK_FILE, 'w') as f:
                json.dump(lock_info, f)
            self.log_info(f"Lock establecido: {self.LOCK_FILE}")
            return True
        except IOError as e:
            self.log_error(f"No se pudo crear el archivo de lock: {e}")
            return False
    
    def eliminar_lock(self):
        """Elimina el lock si pertenece a este proceso"""
        if self.LOCK_FILE.exists():
            try:
                with open(self.LOCK_FILE, 'r') as f:
                    lock_info = json.load(f)
                
                if lock_info.get('pid') == os.getpid():
                    self.LOCK_FILE.unlink()
                    self.log_info("Lock eliminado")
            except (json.JSONDecodeError, IOError):
                # Si no podemos leer el lock, lo eliminamos de todas formas
                self.LOCK_FILE.unlink()
                self.log_info("Lock eliminado (forzado)")
    
    def construir_opciones_rsync(self):
        """Construye las opciones para el comando rsync"""
        opts = [
            "--recursive",
            "--verbose",
            "--times",
            "--progress",
            "--whole-file",
            "--no-links",
            "--itemize-changes"
        ]
        
        if not self.overwrite:
            opts.append("--update")
        
        if self.dry_run:
            opts.append("--dry-run")
        
        if self.delete:
            opts.append("--delete-delay")
        
        if self.use_checksum:
            opts.append("--checksum")
        
        if self.bw_limit:
            opts.append(f"--bwlimit={self.bw_limit}")
        
        # Añadir exclusiones desde configuración y CLI
        exclusiones = self.get_exclusiones()
        for patron in exclusiones:
            opts.append(f"--exclude={patron}")
        
        return opts
    
    def sincronizar_elemento(self, elemento):
        """Sincroniza un elemento individual"""
        pcloud_dir = self.get_pcloud_dir()
        
        if self.modo == "subir":
            origen = self.config.LOCAL_DIR / elemento
            destino = pcloud_dir / elemento
            direccion = "LOCAL → PCLOUD (Subir)"
        else:
            origen = pcloud_dir / elemento
            destino = self.config.LOCAL_DIR / elemento
            direccion = "PCLOUD → LOCAL (Bajar)"
        
        # Verificar si el origen existe
        if not origen.exists():
            self.log_warn(f"No existe {origen}")
            return False
        
        # Normalizar si es directorio
        if origen.is_dir():
            origen = Path(str(origen) + "/")
            destino = Path(str(destino) + "/")
        
        # Advertencia si tiene espacios
        if " " in str(elemento):
            self.log_warn(f"El elemento contiene espacios: '{elemento}'")
        
        # Crear directorio destino si no existe
        dir_destino = destino.parent
        if not dir_destino.exists() and not self.dry_run:
            dir_destino.mkdir(parents=True, exist_ok=True)
            self.log_info(f"Directorio creado: {dir_destino}")
        elif not dir_destino.exists() and self.dry_run:
            self.log_info(f"SIMULACIÓN: Se crearía directorio: {dir_destino}")
        
        self.log_info(f"{self.config.BLUE}Sincronizando: {elemento} ({direccion}){self.config.NC}")
        
        # Construir comando rsync
        opts = self.construir_opciones_rsync()
        cmd = ["rsync"] + opts + [str(origen), str(destino)]
        
        # Ejecutar comando
        try:
            self.log_debug(f"Ejecutando: {' '.join(cmd)}")
            
            if self.dry_run:
                # En dry-run, solo mostramos el comando
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=self.timeout_minutes * 60)
                if result.returncode == 0:
                    self.analizar_salida_rsync(result.stdout)
                    self.log_success(f"Sincronización completada: {elemento}")
                    return True
                else:
                    self.log_error(f"Error en simulación: {elemento}")
                    return False
            else:
                # Ejecución real
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=self.timeout_minutes * 60)
                if result.returncode == 0:
                    self.analizar_salida_rsync(result.stdout)
                    self.log_success(f"Sincronización completada: {elemento}")
                    return True
                else:
                    self.log_error(f"Error en sincronización: {elemento}")
                    self.errores_sincronizacion += 1
                    return False
        except subprocess.TimeoutExpired:
            self.log_error(f"TIMEOUT: La sincronización de '{elemento}' excedió el límite")
            self.errores_sincronizacion += 1
            return False
        except Exception as e:
            self.log_error(f"Error ejecutando rsync: {e}")
            self.errores_sincronizacion += 1
            return False
    
    def analizar_salida_rsync(self, output):
        """Analiza la salida de rsync para obtener estadísticas"""
        lineas = output.split('\n')
        
        # Contar archivos creados y actualizados
        creados = sum(1 for linea in lineas if linea.startswith('>f'))
        actualizados = sum(1 for linea in lineas if linea.startswith('>f.st'))
        count = sum(1 for linea in lineas if linea.startswith(('>', '<')))
        
        # Contar borrados si se usa --delete
        if self.delete:
            borrados = sum(1 for linea in lineas if '*deleting' in linea)
            self.archivos_borrados += borrados
            self.log_info(f"Archivos borrados: {borrados}")
        
        # Actualizar contadores globales
        self.archivos_transferidos += count
        self.elementos_procesados += 1
        
        self.log_info(f"Archivos creados: {creados}")
        self.log_info(f"Archivos actualizados: {actualizados}")
    
    # NUEVA FUNCIÓN: Sincronización de directorio Crypto
    def sincronizar_crypto(self):
        """Sincroniza el directorio Crypto"""
        # Preparar rutas según el modo (subir/bajar) y hostname
        if self.hostname == self.config.HOSTNAME_RTVA:
            if self.modo == "subir":
                origen = self.config.LOCAL_CRYPTO_HOSTNAME_RTVA_DIR
                destino = self.config.REMOTO_CRYPTO_HOSTNAME_RTVA_DIR
                direccion = "LOCAL → PCLOUD (Crypto Subir - RTVA)"
            else:
                origen = self.config.REMOTO_CRYPTO_HOSTNAME_RTVA_DIR
                destino = self.config.LOCAL_CRYPTO_HOSTNAME_RTVA_DIR
                direccion = "PCLOUD → LOCAL (Crypto Bajar - RTVA)"
        else:
            if self.modo == "subir":
                origen = self.config.LOCAL_CRYPTO_DIR
                destino = self.config.REMOTO_CRYPTO_DIR
                direccion = "LOCAL → PCLOUD (Crypto Subir)"
            else:
                origen = self.config.REMOTO_CRYPTO_DIR
                destino = self.config.LOCAL_CRYPTO_DIR
                direccion = "PCLOUD → LOCAL (Crypto Bajar)"
        
        # Verificar si el origen existe
        if not origen.exists():
            self.log_warn(f"No existe {origen}, creando directorio...")
            if not self.dry_run:
                origen.mkdir(parents=True, exist_ok=True)
        
        # Normalizar si es directorio
        if origen.is_dir():
            origen = Path(str(origen) + "/")
            destino = Path(str(destino) + "/")
        
        print("------------------------------------------")
        self.log_info(f"{self.config.BLUE}Sincronizando Crypto: {origen} -> {destino} ({direccion}){self.config.NC}")
        self.log_info("Iniciando sincronización de directorio Crypto...")
        
        # Construir opciones de rsync específicas para Crypto
        crypto_opts = [
            "--recursive",
            "--verbose",
            "--times",
            "--progress",
            "--whole-file",
            "--itemize-changes"
        ]
        
        if not self.overwrite:
            crypto_opts.append("--update")
        
        if self.dry_run:
            crypto_opts.append("--dry-run")
        
        if self.delete:
            crypto_opts.append("--delete-delay")
        
        if self.use_checksum:
            crypto_opts.append("--checksum")
        
        # Excluir el archivo de verificación de montaje
        crypto_opts.append(f"--exclude={self.config.CLOUD_MOUNT_CHECK_FILE}")
        
        # Añadir exclusiones de línea de comandos
        exclusiones = self.get_exclusiones()
        for patron in exclusiones:
            crypto_opts.append(f"--exclude={patron}")
        
        # Sincronizar Keepass2Android (pcloud -> ~/Cripto) - siempre en ambas direcciones
        self.log_info("Sincronizando Keepass2Android...")
        keepass_cmd = ["rsync"] + crypto_opts + [
            str(self.config.REMOTE_KEEPASS_DIR) + "/",
            str(self.config.LOCAL_KEEPASS_DIR) + "/"
        ]
        
        try:
            self.log_debug(f"Ejecutando Keepass sync: {' '.join(keepass_cmd)}")
            result_keepass = subprocess.run(keepass_cmd, capture_output=True, text=True, 
                                          timeout=self.timeout_minutes * 60)
            if result_keepass.returncode != 0:
                self.log_error("Error sincronizando Keepass2Android")
        except Exception as e:
            self.log_error(f"Error en sincronización Keepass2Android: {e}")
        
        # Sincronizar directorio Crypto principal
        crypto_cmd = ["rsync"] + crypto_opts + [str(origen), str(destino)]
        
        try:
            self.log_debug(f"Ejecutando Crypto sync: {' '.join(crypto_cmd)}")
            
            # Usar archivo temporal para capturar salida
            with self.manejo_temporal_context() as temp_ctx:
                temp_output = temp_ctx.temp_file(suffix='.crypto_output', mode='w+')
                
                if self.dry_run:
                    result = subprocess.run(crypto_cmd, stdout=temp_output, stderr=subprocess.STDOUT, 
                                          text=True, timeout=self.timeout_minutes * 60)
                else:
                    result = subprocess.run(crypto_cmd, stdout=temp_output, stderr=subprocess.STDOUT,
                                          timeout=self.timeout_minutes * 60)
                
                # Analizar salida para contar archivos transferidos
                temp_output.seek(0)
                output_content = temp_output.read()
                crypto_count = sum(1 for linea in output_content.split('\n') 
                                 if linea.startswith(('>', '<')))
                self.archivos_crypto_transferidos += crypto_count
            
            if result.returncode == 0:
                self.log_success(f"Sincronización Crypto completada: {crypto_count} archivos transferidos")
                print("------------------------------------------")
                return True
            elif result.returncode == 124:  # timeout
                self.log_error("TIMEOUT: La sincronización Crypto excedió el límite")
                self.errores_sincronizacion += 1
                return False
            else:
                self.log_error(f"Error en sincronización Crypto (código: {result.returncode})")
                self.errores_sincronizacion += 1
                return False
                
        except subprocess.TimeoutExpired:
            self.log_error("TIMEOUT: La sincronización Crypto excedió el límite")
            self.errores_sincronizacion += 1
            return False
        except Exception as e:
            self.log_error(f"Error ejecutando rsync para Crypto: {e}")
            self.errores_sincronizacion += 1
            return False
    
    def procesar_elementos(self):
        """Procesa todos los elementos a sincronizar"""
        exit_code = 0
        
        elementos = self.get_lista_sincronizacion()
 
        if self.items_especificos:
            self.log_info(f"Sincronizando {len(self.items_especificos)} elementos específicos")
            for elemento in self.items_especificos:
                if not self.sincronizar_elemento(elemento):
                    exit_code = 1
                print("-" * 50)
        else:
            self.log_info(f"Procesando lista de sincronización: {len(elementos)} elementos")
            for elemento in elementos:
                if not self.sincronizar_elemento(elemento):
                    exit_code = 1
                print("-" * 50)
        
        return exit_code
    
    def manejar_enlaces_simbolicos(self):
        """Maneja la sincronización de enlaces simbólicos"""
        if self.modo == "subir":
            return self.generar_archivo_enlaces()
        else:
            return self.recrear_enlaces_desde_archivo()
    
    def generar_archivo_enlaces(self):
        """Genera el archivo de metadatos de enlaces simbólicos"""
        pcloud_dir = self.get_pcloud_dir()
        
        # Usar el nuevo sistema de temporales
        with self.manejo_temporal_context() as temp_ctx:
            archivo_enlaces = temp_ctx.temp_file(suffix='.meta', mode='w')
            
            try:
                self.log_info("Generando archivo de enlaces simbólicos...")
                
                elementos = self.items_especificos if self.items_especificos else self.get_lista_sincronizacion()
                
                for elemento in elementos:
                    ruta_completa = self.config.LOCAL_DIR / elemento
                    
                    if ruta_completa.is_symlink():
                        self.registrar_enlace(ruta_completa, archivo_enlaces)
                    elif ruta_completa.is_dir():
                        self.buscar_enlaces_en_directorio(ruta_completa, archivo_enlaces)
                
                archivo_enlaces.close()
                
                # Sincronizar archivo de enlaces a pCloud
                if os.path.getsize(archivo_enlaces.name) > 0:
                    self.log_info("Sincronizando archivo de enlaces...")
                    opts = self.construir_opciones_rsync()
                    cmd = ["rsync"] + opts + [archivo_enlaces.name, f"{pcloud_dir}/{self.config.SYMLINKS_FILE}"]
                    
                    result = subprocess.run(cmd, capture_output=True, text=True)
                    if result.returncode == 0:
                        self.log_info(f"Enlaces detectados/guardados en meta: {self.enlaces_detectados}")
                        self.log_info("Archivo de enlaces sincronizado")
                    else:
                        self.log_error("Error sincronizando archivo de enlaces")
                        return False
                else:
                    self.log_info("No se encontraron enlaces simbólicos para registrar")
                
                return True
            except Exception as e:
                self.log_error(f"Error generando archivo de enlaces: {e}")
                return False
    
    def registrar_enlace(self, enlace, archivo):
        """Registra un enlace simbólico en el archivo de metadatos"""
        try:
            # Ruta relativa del enlace
            ruta_relativa = enlace.relative_to(self.config.LOCAL_DIR)
            
            # Destino del enlace
            destino = os.readlink(str(enlace))
            
            # Normalización del destino
            if destino.startswith(str(self.config.LOCAL_DIR)):
                destino = destino.replace(str(self.config.LOCAL_DIR), "/home/$USERNAME", 1)
            elif destino.startswith("/home/"):
                # Reemplazar nombre de usuario específico por variable
                partes = destino.split('/')
                if len(partes) >= 3:
                    destino = f"/home/$USERNAME/{'/'.join(partes[3:])}"
            
            # Escribir en archivo
            archivo.write(f"{ruta_relativa}\t{destino}\n")
            self.enlaces_detectados += 1
            self.log_debug(f"Registrado enlace: {ruta_relativa} -> {destino}")
        except Exception as e:
            self.log_error(f"Error registrando enlace {enlace}: {e}")
    
    def buscar_enlaces_en_directorio(self, directorio, archivo):
        """Busca enlaces simbólicos en un directorio"""
        try:
            for root, dirs, files in os.walk(str(directorio)):
                for name in files + dirs:
                    ruta_completa = Path(root) / name
                    if ruta_completa.is_symlink():
                        self.registrar_enlace(ruta_completa, archivo)
        except Exception as e:
            self.log_error(f"Error buscando enlaces en {directorio}: {e}")
    
    def recrear_enlaces_desde_archivo(self):
        """Recrea enlaces simbólicos desde el archivo de metadatos"""
        pcloud_dir = self.get_pcloud_dir()
        archivo_enlaces_origen = pcloud_dir / self.config.SYMLINKS_FILE
        archivo_enlaces_local = self.config.LOCAL_DIR / self.config.SYMLINKS_FILE
        
        self.log_info("Buscando archivo de enlaces...")
        
        # Usar el nuevo sistema de temporales
        with self.manejo_temporal_context() as temp_ctx:
            # Copiar archivo localmente si existe en pCloud
            archivo_enlaces_origen = pcloud_dir / self.config.SYMLINKS_FILE
            if archivo_enlaces_origen.exists():
                shutil.copy2(str(archivo_enlaces_origen), str(archivo_enlaces_local))
                self.log_info("Archivo de enlaces copiado localmente")
                # Registrar para cleanup
                self.registrar_temp_file(str(archivo_enlaces_local))
            elif archivo_enlaces_local.exists():
                self.log_info("Usando archivo de enlaces local existente")
                # Registrar para cleanup
                self.registrar_temp_file(str(archivo_enlaces_local))
            else:
                self.log_info("No se encontró archivo de enlaces, omitiendo recreación")
                return True
        
        self.log_info("Recreando enlaces simbólicos...")
        exit_code = 0
        
        try:
            with open(archivo_enlaces_local, 'r', encoding='utf-8') as f:
                for linea in f:
                    linea = linea.strip()
                    if not linea or '\t' not in linea:
                        continue
                    
                    ruta_enlace, destino = linea.split('\t', 1)
                    
                    if not self.procesar_linea_enlace(ruta_enlace, destino):
                        exit_code = 1
            
            self.log_info(f"Enlaces recreados: {self.enlaces_creados}, Errores: {self.enlaces_errores}")
            return exit_code == 0
        except Exception as e:
            self.log_error(f"Error recreando enlaces: {e}")
            return False
    
    def procesar_linea_enlace(self, ruta_enlace, destino):
        """Procesa una línea del archivo de enlaces"""
        try:
            ruta_completa = self.config.LOCAL_DIR / ruta_enlace
            dir_padre = ruta_completa.parent
            
            # Normalizar destino
            destino = destino.replace('$USERNAME', os.getlogin())
            if destino.startswith('/home/$USERNAME'):
                destino = destino.replace('/home/$USERNAME', str(self.config.LOCAL_DIR), 1)
            
            # Crear directorio padre si no existe
            if not dir_padre.exists() and not self.dry_run:
                dir_padre.mkdir(parents=True, exist_ok=True)
            
            # Si ya existe y apunta a lo mismo
            if ruta_completa.is_symlink():
                destino_actual = os.readlink(str(ruta_completa))
                if destino_actual == destino:
                    self.log_debug(f"Enlace ya existe y es correcto: {ruta_enlace} -> {destino}")
                    self.enlaces_existentes += 1
                    return True
                # Eliminar enlace existente incorrecto
                if not self.dry_run:
                    ruta_completa.unlink()
            
            # Crear el enlace
            if self.dry_run:
                self.log_debug(f"SIMULACIÓN: ln -sfn '{destino}' '{ruta_completa}'")
                self.enlaces_creados += 1
            else:
                os.symlink(destino, str(ruta_completa))
                self.log_debug(f"Creado enlace: {ruta_enlace} -> {destino}")
                self.enlaces_creados += 1
            
            return True
        except Exception as e:
            self.log_error(f"Error creando enlace {ruta_enlace} -> {destino}: {e}")
            self.enlaces_errores += 1
            return False
    
    def mostrar_estadisticas(self):
        """Muestra estadísticas de la sincronización"""
        tiempo_total = time.time() - self.start_time
        horas, rem = divmod(tiempo_total, 3600)
        minutos, segundos = divmod(rem, 60)
        
        print("")
        print("=" * 50)
        print("RESUMEN DE SINCRONIZACIÓN")
        print("=" * 50)
        print(f"Elementos procesados: {self.elementos_procesados}")
        print(f"Archivos transferidos: {self.archivos_transferidos}")
        
        # NUEVO: Mostrar estadísticas de Crypto si se usó
        if self.sync_crypto:
            print(f"Archivos Crypto transferidos: {self.archivos_crypto_transferidos}")
        
        if self.delete:
            print(f"Archivos borrados en destino: {self.archivos_borrados}")
        
        exclusiones = self.get_exclusiones()
        if exclusiones:
            print(f"Exclusiones aplicadas: {len(exclusiones)} patrones")
        
        print(f"Enlaces manejados: {self.enlaces_creados + self.enlaces_existentes}")
        print(f"  - Enlaces detectados/guardados: {self.enlaces_detectados}")
        print(f"  - Enlaces creados: {self.enlaces_creados}")
        print(f"  - Enlaces existentes: {self.enlaces_existentes}")
        print(f"  - Enlaces con errores: {self.enlaces_errores}")
        print(f"Errores de sincronización: {self.errores_sincronizacion}")
        
        if tiempo_total >= 3600:
            print(f"Tiempo total: {int(horas)}h {int(minutos)}m {int(segundos)}s")
        elif tiempo_total >= 60:
            print(f"Tiempo total: {int(minutos)}m {int(segundos)}s")
        else:
            print(f"Tiempo total: {int(segundos)}s")
        
        if tiempo_total > 0:
            velocidad_promedio = self.archivos_transferidos / tiempo_total
            print(f"Velocidad promedio: {velocidad_promedio:.2f} archivos/segundo")
        
        print(f"Modo: {'SIMULACIÓN' if self.dry_run else 'EJECUCIÓN REAL'}")
        print("=" * 50)
        
    def ajustar_permisos_ejecutables(self):
        """Ajusta los permisos de ejecución de los archivos configurados"""
        if 'permisos_ejecutables' not in self.config.config_data:
            return True
            
        exit_code = 0
        
        for patron in self.config.PERMISOS_FILES:
            # Si el patrón tiene *, usamos glob
            if '*' in patron:
                archivos = list(self.config.LOCAL_DIR.glob(patron))
                for archivo in archivos:
                    if archivo.is_file():
                        try:
                            if not self.dry_run:
                                archivo.chmod(archivo.stat().st_mode | 0o111)
                            self.log_debug(f"Permisos de ejecución añadidos: {archivo}")
                        except Exception as e:
                            self.log_error(f"Error añadiendo permisos a {archivo}: {e}")
                            exit_code = 1
            else:
                # Ruta específica
                archivo = self.config.LOCAL_DIR / patron
                if archivo.exists() and archivo.is_file():
                    try:
                        if not self.dry_run:
                            archivo.chmod(archivo.stat().st_mode | 0o111)
                        self.log_debug(f"Permisos de ejecución añadidos: {archivo}")
                    except Exception as e:
                        self.log_error(f"Error añadiendo permisos a {archivo}: {e}")
                        exit_code = 1
                else:
                    self.log_warn(f"El archivo para permisos de ejecución no existe: {archivo}")
                                
        return exit_code == 0
    
    def check_log_rotation(self):
        """Comprueba y realiza la rotación de logs si es necesario"""
        try:
            if self.config.LOG_FILE.exists():
                # Rotar manualmente si el archivo actual excede el tamaño máximo
                max_bytes = 10 * 1024 * 1024  # 10 MB
                if self.config.LOG_FILE.stat().st_size > max_bytes:
                    # Encontrar el manejador de archivo
                    for handler in self.logger.handlers:
                        if isinstance(handler, RotatingFileHandler):
                            handler.doRollover()
                            self.log_info("Log rotado automáticamente por tamaño")
                            break
        except Exception as e:
            self.log_error(f"Error en rotación de logs: {e}")    
 
    def enviar_notificacion(self, titulo, mensaje, tipo="info"):
        """
        Envía una notificación del sistema usando métodos nativos
        
        Args:
            titulo (str): Título de la notificación
            mensaje (str): Mensaje de la notificación
            tipo (str): Tipo de notificación (info, warning, error)
        """
        
        # Verificar si las notificaciones están habilitadas
        if not self.config.NOTIFICATIONS_ENABLED:
            return
        
        try:
            sistema = platform.system()
            
            if sistema == "Linux":
                # Para Linux (GNOME, KDE, etc.) usando notify-send
                urgencia = "normal"
                if tipo == "error":
                    urgencia = "critical"
                elif tipo == "warning":
                    urgencia = "normal"
                
                comando = [
                    "notify-send", 
                    "-u", urgencia,
                    titulo,
                    mensaje
                ]
                
                # Intentar ejecutar el comando
                subprocess.run(comando, check=False, timeout=5)
                
            elif sistema == "Darwin":  # macOS
                # Para macOS usando osascript
                script = f'display notification "{mensaje}" with title "{titulo}"'
                comando = ["osascript", "-e", script]
                subprocess.run(comando, check=False, timeout=5)
                
            elif sistema == "Windows":
                # Para Windows usando powershell
                script = f'[System.Windows.Forms.MessageBox]::Show("{mensaje}", "{titulo}")'
                comando = ["powershell", "-Command", script]
                subprocess.run(comando, check=False, timeout=5)
                
            else:
                # Fallback: mostrar en terminal
                self.log_info(f"🔔 {titulo}: {mensaje}")
                
        except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
            # Si falla el comando, mostrar en terminal
            self.log_info(f"🔔 {titulo}: {mensaje}")
        except Exception as e:
            # Cualquier otro error, mostrar en terminal y log
            self.log_info(f"🔔 {titulo}: {mensaje}")
            self.log_debug(f"Error enviando notificación: {e}")
    
    def run_tests(self):
        """Ejecuta tests unitarios"""
        print("Ejecutando tests unitarios...")
        tests_pasados = 0
        tests_fallados = 0
        
        # Test 1: get_pcloud_dir
        print("Test 1: get_pcloud_dir")
        self.backup_dir_mode = "comun"
        pcloud_dir_comun = self.get_pcloud_dir()
        self.backup_dir_mode = "readonly"
        pcloud_dir_readonly = self.get_pcloud_dir()
        
        if (pcloud_dir_comun == self.config.PCLOUD_BACKUP_COMUN and 
            pcloud_dir_readonly == self.config.PCLOUD_BACKUP_READONLY):
            tests_pasados += 1
            print("PASS: get_pcloud_dir")
        else:
            tests_fallados += 1
            print("FAIL: get_pcloud_dir")
        
        # Test 2: construir_opciones_rsync
        print("Test 2: construir_opciones_rsync")
        self.overwrite = False
        self.dry_run = False
        self.delete = False
        self.use_checksum = False
        self.bw_limit = None
        opts_base = self.construir_opciones_rsync()
        
        self.overwrite = True
        opts_overwrite = self.construir_opciones_rsync()
        
        self.delete = True
        opts_delete = self.construir_opciones_rsync()
        
        if (len(opts_base) != len(opts_overwrite) and 
            len(opts_base) != len(opts_delete)):
            tests_pasados += 1
            print("PASS: construir_opciones_rsync")
        else:
            tests_fallados += 1
            print("FAIL: construir_opciones_rsync")
        
        # Resumen de tests
        print("")
        print("=" * 50)
        print("RESUMEN DE TESTS")
        print("=" * 50)
        print(f"Tests pasados: {tests_pasados}")
        print(f"Tests fallados: {tests_fallados}")
        print(f"Total tests: {tests_pasados + tests_fallados}")
        
        return tests_fallados == 0
    
    def main(self):
        """Función principal"""
        try:
            # Procesar argumentos
            self.parse_arguments()
            
            # Mostrar banner
            self.mostrar_banner()
            
            # Establecer lock
            if not self.establecer_lock():
                sys.exit(1)
            
            # Verificar dependencias
            if not shutil.which("rsync"):
                self.log_error("rsync no está instalado. Instálalo con:")
                self.log_info("sudo apt install rsync  # Debian/Ubuntu")
                self.log_info("sudo dnf install rsync  # RedHat/CentOS")
                sys.exit(1)
   
            # Verificaciones mejoradas
            if not self.verificar_pcloud_montado():
                self.verificar_estado_pcloud()
                sys.exit(1)
                
            # Verificar espacio en pCloud
            self.verificar_espacio_pcloud()
        
            # Verificar conectividad
            self.verificar_conectividad_pcloud()
            
            # Verificar espacio en disco
            if not self.verificar_espacio_disco(500):  # 500 MB mínimo
                self.log_warn("Espacio en disco bajo, pero continuando...")
            
            # Confirmar ejecución
            if not self.dry_run:
                self.confirmar_ejecucion()
            
            # Inicializar log
            self.log_info("Iniciando proceso de sincronización")
            
            # Procesar elementos
            exit_code = self.procesar_elementos()
            
            # NUEVO: Sincronizar directorio Crypto si está habilitado
            if self.sync_crypto:
                if not self.sincronizar_crypto():
                    exit_code = 1
                else:
                    self.log_info("Sincronización Crypto completada correctamente")
            else:
                self.log_info("Sincronización de directorio Crypto excluida")
            
            # cambiar permisos de ficheros ejecutables cuando se bajan
            if self.modo == "bajar":
                if self.ajustar_permisos_ejecutables():
                    self.log_info(f"Permisos de ejecución añadidos")
            
            # Manejar enlaces simbólicos
            if not self.manejar_enlaces_simbolicos():
                exit_code = 1
            
            # Mostrar estadísticas
            self.mostrar_estadisticas()
                
            # Notificar finalización
            if not self.dry_run:
                tipo = "info" if exit_code == 0 else "error"
                mensaje = (f"Sincronización {'completada' if exit_code == 0 else 'fallada'}\n"
                          f"Elementos: {self.elementos_procesados}, "
                          f"Transferidos: {self.archivos_transferidos}")
                
                # NUEVO: Incluir estadísticas de Crypto en la notificación
                if self.sync_crypto:
                    mensaje += f", Crypto: {self.archivos_crypto_transferidos}"
                
                self.enviar_notificacion(
                    f"Sincronización {'Completada' if exit_code == 0 else 'Fallida'}",
                    mensaje,
                    tipo
                )            
            
            return exit_code
            
        except KeyboardInterrupt:
            self.log_info("Operación cancelada por el usuario")
            return 1
        except Exception as e:
            self.log_error(f"Error inesperado: {e}")
            return 1
        finally:
            # Eliminar lock
            self.eliminar_lock()
        
            # Registrar en log
            with open(self.config.LOG_FILE, 'a', encoding='utf-8') as f:
                f.write("=" * 50 + "\n")
                f.write(f"Sincronización finalizada: {datetime.datetime.now().isoformat()}\n")
                f.write(f"Elementos procesados: {self.elementos_procesados}\n")
                f.write(f"Archivos transferidos: {self.archivos_transferidos}\n")
                
                # NUEVO: Registrar estadísticas de Crypto
                if self.sync_crypto:
                    f.write(f"Archivos Crypto transferidos: {self.archivos_crypto_transferidos}\n")
                
                if self.delete:
                    f.write(f"Archivos borrados: {self.archivos_borrados}\n")
                exclusiones = self.get_exclusiones()
                if exclusiones:
                    f.write(f"Exclusiones aplicadas: {len(exclusiones)}\n")
                f.write(f"Modo dry-run: {'Sí' if self.dry_run else 'No'}\n")
                f.write(f"Enlaces detectados/guardados: {self.enlaces_detectados}\n")
                f.write(f"Enlaces creados: {self.enlaces_creados}\n")
                f.write(f"Enlaces existentes: {self.enlaces_existentes}\n")
                f.write(f"Enlaces con errores: {self.enlaces_errores}\n")
                f.write(f"Errores generales: {self.errores_sincronizacion}\n")
                f.write(f"Log: {self.config.LOG_FILE}\n")
                f.write("=" * 50 + "\n")

            # Cleanup de temporales (se ejecutará automáticamente por atexit,
            # pero lo llamamos aquí también para limpieza inmediata)
            self.cleanup_temporales()
            

if __name__ == "__main__":
    app = SyncBidireccional()
    sys.exit(app.main())
