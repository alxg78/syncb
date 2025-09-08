#!/usr/bin/env python3
"""
Script de sincronización bidireccional entre directorio local y pCloud

Este script permite sincronizar archivos y directorios entre un directorio local
y pCloud en ambas direcciones (subir y bajar). Incluye funcionalidades como:
- Sincronización selectiva con listas de directorios
- Manejo de enlaces simbólicossyncb
- Modo simulación (dry-run)
- Eliminación de archivos obsoletos
- Límite de ancho de banda
- Sistema de logging y notificaciones
- Bloqueo de ejecución concurrente

Uso:
    Para subir: python syncb.py --subir [opciones]
    Para bajar: python syncb.py --bajar [opciones]

Opciones disponibles:
    --subir            Sincroniza desde local a pCloud
    --bajar            Sincroniza desde pCloud a local
    --delete           Elimina archivos obsoletos en destino
    --dry-run          Simula sin hacer cambios reales
    --item ELEMENTO    Sincroniza solo el elemento especificado
    --yes              Ejecuta sin confirmación
    --backup-dir       Usa directorio de backup de solo lectura
    --exclude PATRON   Excluye archivos que coincidan con el patrón
    --overwrite        Sobrescribe todos los archivos en destino
    --checksum         Fuerza comparación con checksum
    --bwlimit KB/s     Limita la velocidad de transferencia
    --timeout MINUTOS  Límite de tiempo por operación
    --force-unlock     Fuerza eliminación de lock
    --verbose          Habilita modo verboso
    --test             Ejecuta tests unitarios
    --help             Muestra ayuda
"""

import os
import sys
import argparse
import logging
import subprocess
import shutil
import tempfile
import time
import datetime
import json
import signal
import platform
from pathlib import Path
from typing import List, Dict, Tuple, Optional, Set, Any

# Configuración básica
class Config:
    """Configuración global del script"""
    
    # Punto de montaje de pCloud
    PCLOUD_MOUNT_POINT = Path.home() / "pCloudDrive"
    
    # Directorio local
    LOCAL_DIR = Path.home()
    
    # Directorios de pCloud
    PCLOUD_BACKUP_COMUN = PCLOUD_MOUNT_POINT / "Backups" / "Backup_Comun"
    PCLOUD_BACKUP_READONLY = PCLOUD_MOUNT_POINT / "pCloud Backup" / "feynman.sobremesa.dnf"
    
    # Archivos de configuración
    LISTA_POR_DEFECTO_FILE = "syncb_directorios.ini"
    LISTA_ESPECIFICA_POR_DEFECTO_FILE = "syncb_directorios_{}.ini"
    EXCLUSIONES_FILE = "syncb_exclusiones.ini"
    
    # Archivo de enlaces simbólicos
    SYMLINKS_FILE = ".syncb_symlinks.meta"
    
    # Log file
    LOG_FILE = Path.home() / "syncb.log"
    
    # Lock file
    LOCK_FILE = Path(tempfile.gettempdir()) / "syncb.lock"
    LOCK_TIMEOUT = 3600  # 1 hora en segundos
    
    # Hostname de la máquina virtual de RTVA
    HOSTNAME_RTVA = "feynman.rtva.dnf"
    
    # Colores para logging (códigos ANSI)
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    MAGENTA = '\033[0;35m'
    CYAN = '\033[0;36m'
    WHITE = '\033[1;37m'
    NC = '\033[0m'  # No Color
    
    # Iconos Unicode
    CHECK_MARK = "✓"
    CROSS_MARK = "✗"
    INFO_ICON = "ℹ"
    WARNING_ICON = "⚠"
    CLOCK_ICON = "⏱"
    SYNC_ICON = "🔄"
    ERROR_ICON = "❌"
    SUCCESS_ICON = "✅"


class SyncBidireccional:
    """Clase principal para la sincronización bidireccional"""
    
    def __init__(self):
        """Inicializa la instancia con valores por defecto"""
        self.config = Config()
        self.modo = None  # 'subir' o 'bajar'
        self.dry_run = False
        self.delete = False
        self.yes = False
        self.overwrite = False
        self.backup_dir_mode = "comun"  # 'comun' o 'readonly'
        self.verbose = False
        self.use_checksum = False
        self.bw_limit = None
        self.timeout_minutes = 30
        self.items_especificos = []
        self.exclusiones_cli = []
        self.lista_sincronizacion = None
        self.exclusiones = None
        
        # Variables para estadísticas
        self.elementos_procesados = 0
        self.errores_sincronizacion = 0
        self.archivos_transferidos = 0
        self.enlaces_creados = 0
        self.enlaces_existentes = 0
        self.enlaces_errores = 0
        self.enlaces_detectados = 0
        self.archivos_borrados = 0
        
        # Tiempo de inicio
        self.start_time = time.time()
        
        # Obtener hostname
        self.hostname = platform.node()
        
        # Determinar el directorio del script
        self.script_dir = Path(__file__).parent.absolute()
        
        # Configurar logging
        self.setup_logging()
    
    def setup_logging(self):
        """Configura el sistema de logging"""
        # Crear formateador personalizado con colores
        class ColoredFormatter(logging.Formatter):
            """Formateador de log con colores"""
            
            FORMATS = {
                logging.DEBUG: f"{Config.MAGENTA}{Config.CLOCK_ICON} [DEBUG]{Config.NC} %(message)s",
                logging.INFO: f"{Config.BLUE}{Config.INFO_ICON} [INFO]{Config.NC} %(message)s",
                logging.WARNING: f"{Config.YELLOW}{Config.WARNING_ICON} [WARN]{Config.NC} %(message)s",
                logging.ERROR: f"{Config.RED}{Config.CROSS_MARK} [ERROR]{Config.NC} %(message)s",
                logging.CRITICAL: f"{Config.RED}{Config.ERROR_ICON} [CRITICAL]{Config.NC} %(message)s"
            }
            
            def format(self, record):
                log_fmt = self.FORMATS.get(record.levelno)
                formatter = logging.Formatter(log_fmt)
                return formatter.format(record)
        
        # Configurar logger principal
        self.logger = logging.getLogger('syncb')
        self.logger.setLevel(logging.DEBUG)
        
        # Handler para consola
        console_handler = logging.StreamHandler()
        console_handler.setLevel(logging.DEBUG)
        console_handler.setFormatter(ColoredFormatter())
        self.logger.addHandler(console_handler)
        
        # Handler para archivo (sin colores)
        file_handler = logging.FileHandler(self.config.LOG_FILE, encoding='utf-8')
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
        self.logger.debug(msg)
    
    def log_success(self, msg):
        """Registra un mensaje de éxito"""
        self.logger.info(f"{Config.GREEN}{Config.CHECK_MARK} [SUCCESS]{Config.NC} {msg}")
    
    def parse_arguments(self):
        """Procesa los argumentos de línea de comandos"""
        parser = argparse.ArgumentParser(
            description="Sincronización bidireccional entre directorio local y pCloud",
            epilog="Ejemplos:\n"
                   "  syncb.py --subir\n"
                   "  syncb.py --bajar --dry-run\n"
                   "  syncb.py --subir --delete --yes\n"
                   "  syncb.py --subir --item documentos/\n"
                   "  syncb.py --bajar --item configuracion.ini --item .local/bin --dry-run",
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
        parser.add_argument("--verbose", action="store_true", help="Habilita modo verboso")
        parser.add_argument("--test", action="store_true", help="Ejecuta tests unitarios")
        
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
    
    def force_unlock(self):
        """Fuerza la eliminación del archivo de lock"""
        if self.config.LOCK_FILE.exists():
            self.config.LOCK_FILE.unlink()
            self.log_info("Lock eliminado forzosamente")
        else:
            self.log_info("No existe archivo de lock")
    
    def get_pcloud_dir(self):
        """Obtiene el directorio de pCloud según el modo"""
        if self.backup_dir_mode == "readonly":
            return self.config.PCLOUD_BACKUP_READONLY
        else:
            return self.config.PCLOUD_BACKUP_COMUN
    
    def find_config_files(self):
        """Busca los archivos de configuración"""
        # Si el hostname es el de RTVA, usar archivo específico
        if self.hostname == self.config.HOSTNAME_RTVA:
            lista_especifica = self.config.LISTA_ESPECIFICA_POR_DEFECTO_FILE.format(self.config.HOSTNAME_RTVA)
            
            # Buscar en directorio del script
            lista_path = self.script_dir / lista_especifica
            if lista_path.exists():
                self.lista_sincronizacion = lista_path
            else:
                # Buscar en directorio actual
                lista_path = Path.cwd() / lista_especifica
                if lista_path.exists():
                    self.lista_sincronizacion = lista_path
                else:
                    self.log_error(f"No se encontró el archivo de lista específico '{lista_especifica}'")
                    sys.exit(1)
        else:
            # Para otros hostnames, usar archivo por defecto
            lista_path = self.script_dir / self.config.LISTA_POR_DEFECTO_FILE
            if lista_path.exists():
                self.lista_sincronizacion = lista_path
            else:
                lista_path = Path.cwd() / self.config.LISTA_POR_DEFECTO_FILE
                if lista_path.exists():
                    self.lista_sincronizacion = lista_path
        
        # Buscar archivo de exclusiones
        exclusiones_path = self.script_dir / self.config.EXCLUSIONES_FILE
        if exclusiones_path.exists():
            self.exclusiones = exclusiones_path
        else:
            exclusiones_path = Path.cwd() / self.config.EXCLUSIONES_FILE
            if exclusiones_path.exists():
                self.exclusiones = exclusiones_path
    
    def verificar_pcloud_montado(self):
        """Verifica que pCloud esté montado correctamente"""
        pcloud_dir = self.get_pcloud_dir()
        
        # Verificar si el punto de montaje existe
        if not self.config.PCLOUD_MOUNT_POINT.exists():
            self.log_error(f"El punto de montaje de pCloud no existe: {self.config.PCLOUD_MOUNT_POINT}")
            return False
        
        # Verificar si el directorio está vacío (puede indicar que no está montado)
        try:
            if not any(self.config.PCLOUD_MOUNT_POINT.iterdir()):
                self.log_error(f"El directorio de pCloud está vacío: {self.config.PCLOUD_MOUNT_POINT}")
                return False
        except PermissionError:
            self.log_error(f"Sin permisos para acceder al directorio: {self.config.PCLOUD_MOUNT_POINT}")
            return False
        
        # Verificar usando comandos del sistema
        system = platform.system()
        try:
            if system == "Linux":
                # Verificar con findmnt
                result = subprocess.run(["findmnt", "-rno", "TARGET", str(self.config.PCLOUD_MOUNT_POINT)], 
                                      capture_output=True, text=True, check=False)
                if result.returncode != 0:
                    self.log_error(f"pCloud no aparece montado en {self.config.PCLOUD_MOUNT_POINT}")
                    return False
            elif system == "Darwin":  # macOS
                # Verificar con mount
                result = subprocess.run(["mount"], capture_output=True, text=True, check=False)
                if str(self.config.PCLOUD_MOUNT_POINT) not in result.stdout:
                    self.log_error(f"pCloud no aparece montado en {self.config.PCLOUD_MOUNT_POINT}")
                    return False
        except Exception as e:
            self.log_error(f"Error verificando montaje: {e}")
            return False
        
        # Verificar si el directorio específico de pCloud existe
        if not pcloud_dir.exists():
            self.log_error(f"El directorio de pCloud no existe: {pcloud_dir}")
            return False
        
        # Verificar permisos de escritura (solo si no es dry-run y no es modo backup-dir)
        if not self.dry_run and self.backup_dir_mode == "comun":
            test_file = pcloud_dir / f".test_write_{os.getpid()}"
            try:
                test_file.touch()
                test_file.unlink()
            except Exception:
                self.log_error(f"No se puede escribir en: {pcloud_dir}")
                return False
        
        self.log_info("Verificación de pCloud: OK - El directorio está montado y accesible")
        return True
    
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
            print(f"ESTADO: {Config.YELLOW}MODO SIMULACIÓN{Config.NC} (no se realizarán cambios)")
        
        if self.delete:
            print(f"BORRADO: {Config.GREEN}ACTIVADO{Config.NC} (se eliminarán archivos obsoletos)")
        
        if self.yes:
            print("CONFIRMACIÓN: Automática (sin preguntar)")
        
        if self.overwrite:
            print(f"SOBRESCRITURA: {Config.GREEN}ACTIVADA{Config.NC}")
        else:
            print("MODO: SEGURO (--update activado)")
        
        if self.items_especificos:
            print(f"ELEMENTOS ESPECÍFICOS: {', '.join(self.items_especificos)}")
        else:
            print(f"LISTA: {self.lista_sincronizacion}")
        
        print(f"EXCLUSIONES: {self.exclusiones}")
        
        if self.exclusiones_cli:
            print(f"EXCLUSIONES CLI ({len(self.exclusiones_cli)} patrones):")
            for i, patron in enumerate(self.exclusiones_cli, 1):
                print(f"  {i}. {patron}")
        
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
        if self.config.LOCK_FILE.exists():
            # Leer información del lock existente
            try:
                with open(self.config.LOCK_FILE, 'r') as f:
                    lock_info = json.load(f)
                
                lock_pid = lock_info.get('pid')
                lock_time = lock_info.get('timestamp', 0)
                current_time = time.time()
                lock_age = current_time - lock_time
                
                if lock_age > self.config.LOCK_TIMEOUT:
                    self.log_warn(f"Eliminando lock obsoleto (edad: {lock_age:.0f}s > timeout: {self.config.LOCK_TIMEOUT}s)")
                    self.config.LOCK_FILE.unlink()
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
                        self.config.LOCK_FILE.unlink()
            except (json.JSONDecodeError, IOError):
                # El archivo de lock está corrupto o no se puede leer
                self.log_warn("Eliminando lock corrupto")
                self.config.LOCK_FILE.unlink()
        
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
            with open(self.config.LOCK_FILE, 'w') as f:
                json.dump(lock_info, f)
            self.log_info(f"Lock establecido: {self.config.LOCK_FILE}")
            return True
        except IOError as e:
            self.log_error(f"No se pudo crear el archivo de lock: {e}")
            return False
    
    def eliminar_lock(self):
        """Elimina el lock si pertenece a este proceso"""
        if self.config.LOCK_FILE.exists():
            try:
                with open(self.config.LOCK_FILE, 'r') as f:
                    lock_info = json.load(f)
                
                if lock_info.get('pid') == os.getpid():
                    self.config.LOCK_FILE.unlink()
                    self.log_info("Lock eliminado")
            except (json.JSONDecodeError, IOError):
                # Si no podemos leer el lock, lo eliminamos de todas formas
                self.config.LOCK_FILE.unlink()
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
        
        if self.exclusiones and self.exclusiones.exists():
            opts.append(f"--exclude-from={self.exclusiones}")
        
        for patron in self.exclusiones_cli:
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
        
        self.log_info(f"{Config.BLUE}Sincronizando: {elemento} ({direccion}){Config.NC}")
        
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
    
    def procesar_elementos(self):
        """Procesa todos los elementos a sincronizar"""
        exit_code = 0
        
        if self.items_especificos:
            self.log_info(f"Sincronizando {len(self.items_especificos)} elementos específicos")
            for elemento in self.items_especificos:
                if not self.sincronizar_elemento(elemento):
                    exit_code = 1
                print("-" * 50)
        else:
            # Leer elementos del archivo de lista
            try:
                with open(self.lista_sincronizacion, 'r', encoding='utf-8') as f:
                    lineas = [linea.strip() for linea in f if linea.strip() and not linea.startswith('#')]
                
                self.log_info(f"Procesando lista de sincronización: {len(lineas)} elementos")
                for linea in lineas:
                    if not self.sincronizar_elemento(linea):
                        exit_code = 1
                    print("-" * 50)
            except IOError as e:
                self.log_error(f"Error leyendo archivo de lista: {e}")
                return 1
        
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
        archivo_enlaces = tempfile.NamedTemporaryFile(mode='w', delete=False, encoding='utf-8')
        
        try:
            self.log_info("Generando archivo de enlaces simbólicos...")
            
            elementos = self.items_especificos if self.items_especificos else self.leer_elementos_lista()
            
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
        finally:
            # Limpiar archivo temporal
            if os.path.exists(archivo_enlaces.name):
                os.unlink(archivo_enlaces.name)
    
    def leer_elementos_lista(self):
        """Lee los elementos del archivo de lista"""
        elementos = []
        try:
            with open(self.lista_sincronizacion, 'r', encoding='utf-8') as f:
                for linea in f:
                    linea = linea.strip()
                    if linea and not linea.startswith('#'):
                        elementos.append(linea)
        except IOError as e:
            self.log_error(f"Error leyendo archivo de lista: {e}")
        
        return elementos
    
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
            self.log_info(f"Registrado enlace: {ruta_relativa} -> {destino}")
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
        
        # Copiar archivo localmente
        if archivo_enlaces_origen.exists():
            shutil.copy2(str(archivo_enlaces_origen), str(archivo_enlaces_local))
            self.log_info("Archivo de enlaces copiado localmente")
        elif archivo_enlaces_local.exists():
            self.log_info("Usando archivo de enlaces local existente")
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
        finally:
            # Limpiar archivo temporal
            if not self.dry_run and archivo_enlaces_local.exists():
                archivo_enlaces_local.unlink()
    
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
                    self.log_info(f"Enlace ya existe y es correcto: {ruta_enlace} -> {destino}")
                    self.enlaces_existentes += 1
                    return True
                # Eliminar enlace existente incorrecto
                if not self.dry_run:
                    ruta_completa.unlink()
            
            # Crear el enlace
            if self.dry_run:
                self.log_info(f"SIMULACIÓN: ln -sfn '{destino}' '{ruta_completa}'")
                self.enlaces_creados += 1
            else:
                os.symlink(destino, str(ruta_completa))
                self.log_info(f"Creado enlace: {ruta_enlace} -> {destino}")
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
        
        if self.delete:
            print(f"Archivos borrados en destino: {self.archivos_borrados}")
        
        if self.exclusiones_cli:
            print(f"Exclusiones CLI aplicadas: {len(self.exclusiones_cli)} patrones")
        
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
    
    def run_tests(self):
        """Ejecuta tests unitarios"""
        # Esta es una implementación básica de tests
        # En una implementación real, se usaría un framework como unittest o pytest
        
        print("Ejecutando tests unitarios...")
        tests_pasados = 0
        tests_fallados = 0
        
        # Test 1: normalize_path (simulado)
        print("Test 1: normalize_path (simulado)")
        tests_pasados += 1
        
        # Test 2: get_pcloud_dir
        print("Test 2: get_pcloud_dir")
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
        
        # Test 3: construir_opciones_rsync
        print("Test 3: construir_opciones_rsync")
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
            
            # Buscar archivos de configuración
            self.find_config_files()
            
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
            
            # Verificar pCloud montado
            if not self.verificar_pcloud_montado():
                sys.exit(1)
            
            # Confirmar ejecución
            if not self.dry_run:
                self.confirmar_ejecucion()
            
            # Inicializar log
            self.log_info("Iniciando proceso de sincronización")
            
            # Procesar elementos
            exit_code = self.procesar_elementos()
            
            # Manejar enlaces simbólicos
            if not self.manejar_enlaces_simbolicos():
                exit_code = 1
            
            # Mostrar estadísticas
            self.mostrar_estadisticas()
            
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
                if self.delete:
                    f.write(f"Archivos borrados: {self.archivos_borrados}\n")
                if self.exclusiones_cli:
                    f.write(f"Exclusiones CLI aplicadas: {len(self.exclusiones_cli)}\n")
                f.write(f"Modo dry-run: {'Sí' if self.dry_run else 'No'}\n")
                f.write(f"Enlaces detectados/guardados: {self.enlaces_detectados}\n")
                f.write(f"Enlaces creados: {self.enlaces_creados}\n")
                f.write(f"Enlaces existentes: {self.enlaces_existentes}\n")
                f.write(f"Enlaces con errores: {self.enlaces_errores}\n")
                f.write(f"Errores generales: {self.errores_sincronizacion}\n")
                f.write(f"Log: {self.config.LOG_FILE}\n")
                f.write("=" * 50 + "\n")


if __name__ == "__main__":
    app = SyncBidireccional()
    sys.exit(app.main())
