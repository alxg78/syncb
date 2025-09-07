!#/bin/sh

# Instala en el directorio INSTALL_DIR

INSTALL_DIR="${HOME}/.local/bin/"

cp sync_bidireccional.sh ${INSTALL_DIR}
cp sync_bidireccional_directorios_feynman.rtva.dnf.ini ${INSTALL_DIR}
cp sync_bidireccional_directorios.ini ${INSTALL_DIR}
cp sync_bidireccional_exclusiones.ini ${INSTALL_DIR}
cp sync_bidireccional_readme.org ${INSTALL_DIR}

chmod 755 *.sh
