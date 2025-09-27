/*

*/

use std::{fs::File, env};
use std::io::prelude::*;  //read_to_string
use std::path::{PathBuf};

use clap::{App, Arg};
use serde::Deserialize;
use toml::de::Error;
use chrono::Local;
use fslock::LockFile;


// constantes
const INI_FILE: &'static str = "sync.ini";
const LOCK_FILE: &'static str = "sync.lock";
const VERSION: &'static str = env!("CARGO_PKG_VERSION");
const APPNAME: &'static str = env!("CARGO_PKG_NAME");
const AUTOR: &'static str = env!("CARGO_PKG_AUTHORS");
const DESCRIPTION: &'static str = env!("CARGO_PKG_DESCRIPTION");


// init file con toml
#[derive(Deserialize)]
struct Config {
    general: General,
    dirs: Dirs,
}

#[derive(Deserialize)]
struct General {
    dir_data: String,
    dir_bash: String,
    file_logging: String,
}

#[derive(Deserialize)]
struct Dirs {
   dirs_not_exist: Vec<String>,
   dirs_link: Vec<[String; 3]>, 
}



fn load_ini_file() -> Result<Config, Error> {
    let path = current_exe_dir().join(INI_FILE);
    //let path = PathBuf::from(INI_FILE);

    let mut file = match File::open(&path) {
        Ok(f) => f,
        Err(e) => panic!("no existe el fichero {} exception:{}", path.display(), e)
    };
    let mut str_val = String::new();
    match file.read_to_string(&mut str_val) {
        Ok(s) => s,
        Err(e) => panic!("Error leyendo el fichero: {}", e)
    };
    let cfg: Config = toml::from_str(&str_val)?;

    Ok(cfg)
}

fn test_ini_file() -> Result<(), Error> {
    // lee el fichero .ini
    let ini_info = load_ini_file()?;

    //let dir_home = get_dir_home(&ini_info.general.dir_home); //&env::var("HOME").unwrap(); 
    let dir_data = ini_info.general.dir_data;
    let dir_bash = ini_info.general.dir_bash;
    let file_logging = ini_info.general.file_logging;
    let dirs_not_exist = &ini_info.dirs.dirs_not_exist;
    let dirs_link = ini_info.dirs.dirs_link;

    dbg!(dir_data, dir_bash, file_logging, dirs_not_exist, dirs_link);

    Ok(())
}

fn current_exe_dir() -> PathBuf {
    let exe = env::current_exe().expect("No encuentra el path del ejecutable");
    let dir = exe.parent().expect("Ejecutable en el mismo directorio");
    dir.to_path_buf()
}

fn init_logger() {
    let env = env_logger::Env::default().filter_or(env_logger::DEFAULT_FILTER_ENV, "info");
    env_logger::Builder::from_env(env)
        .format(|buf, record| {
            writeln!(
                buf,
                "{} {} [{}] {}",
                Local::now().format("%Y-%m-%d %H:%M:%S"),
                record.level(),
                record.module_path().unwrap_or("<unnamed>"),
                &record.args()
            )
        })
        .init();
 
    //log::info!("env_logger initialized.");
    //log::trace!("trace");
    //log::warn!("warn");
    //log::error!("error");
    //log::info!("info");
    //log::debug!("debug");
}

//fn parse_argv() -> clap::ArgMatches<'static> {
fn parse_argv() -> App<'static> {
    App::new(APPNAME)
        .version(VERSION)
        .author(AUTOR)
        .about(DESCRIPTION)
        //.setting(clap::AppSettings::ArgRequiredElseHelp)  // return error (exit code: 2)
        .arg(Arg::new("diarias").short('d').long("diarias").conflicts_with("mensuales").conflicts_with("test")
                .about("Copias de seguridad diarias"))
        .arg(Arg::new("mensuales").short('m').long("mensuales").conflicts_with("comprime")
                .conflicts_with("test").about("Copias de seguridad mensuales"))
        .arg(Arg::new("comprime").short('c').long("comprime").conflicts_with("test")
                .about("Comprime las copias de seguridad diarias"))
        .arg(Arg::new("test").short('t').long("test").about("Prueba caracteristicas de la aplicación"))
}

fn main() -> Result<(), fslock::Error> {
    //Logging
    init_logger();

    // borrar
    log::info!("Poner el fichero: {} en el mimos directorio que el ejecutable", INI_FILE);

    // fichero de bloqueo
    let path = current_exe_dir().join(LOCK_FILE);
    let mut file = LockFile::open(&path)?;
    if file.try_lock()? {
      
        // linea de comandos
        let matches: clap::ArgMatches = parse_argv().get_matches();

        // Comprueba opciones
        if matches.is_present("test") {
            log::info!("Varios test");
            test_ini_file()?;
        }

        
        // elimina fichero de bloqueo
        file.unlock()?;

    } else { // si no puede bloquear el fichero.
        log::warn!("Ya hay otra instancia de esta aplicación ejecutandose.");
    }

    Ok(())
}






#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() { assert_eq!(2 + 2, 4); }
}
