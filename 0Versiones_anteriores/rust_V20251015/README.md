# Sync

Sincroniza directorios usando *rsync*


## Uso de logging

```sh
$ RUST_LOG ./app
```

```sh
$ RUST_LOG=info ./main
[2018-11-03T06:09:06Z INFO  default] starting up
```

```sh
$ RUST_LOG=INFO ./main
[2018-11-03T06:09:06Z INFO  default] starting up
```


# Caracteristicas

* Argumentos en linea comandos
* Logging
* Solo se ejecuta una vez (bloqueo)
* Fichero de configuracion 


# Requisitos

* clap 
* env_logger 
* fslock 
* toml 



