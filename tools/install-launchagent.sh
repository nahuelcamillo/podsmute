#!/bin/bash
# Instala (o reinstala) el LaunchAgent que arranca PodsMute al iniciar sesion.
#
# El plist NO se versiona tal cual porque lleva rutas absolutas: el binario esta
# dentro del repo y los logs en el home del usuario. Este script lo GENERA con
# las rutas resueltas desde la ubicacion real del repo, asi el arranque
# automatico sobrevive a un reinstall, a clonar en otra ruta o en otra maquina.
#
# Idempotente: se puede correr todas las veces que quieras.
set -euo pipefail

LABEL="com.podsmute.app"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$REPO_ROOT/build/PodsMute.app/Contents/MacOS/PodsMute"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/PodsMute.log"
DOMAIN="gui/$(id -u)"

if [ ! -x "$BINARY" ]; then
    echo "==> No existe el binario: $BINARY"
    echo "    Compila primero con ./build-clt.sh"
    exit 1
fi

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"

echo "==> Escribiendo $PLIST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- GENERADO por tools/install-launchagent.sh. No editar a mano: volve a correr
     el script (las rutas de abajo dependen de donde este clonado el repo). -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <!-- Relanzar SOLO ante crash. AVFAudio lanza NSExceptions que Swift no
         puede atrapar (carreras de tap/formato durante un cambio de ruta de
         audio) y morir a mitad de reunion deja el mic sin control.
         SuccessfulExit=false preserva la intencion original: Quit del menu (y
         SIGTERM, que la app enruta por terminate) sale con 0 y queda quieto. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>

    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

# bootout + bootstrap, no solo bootstrap: launchd "pinea" el code requirement
# del binario cuando registra el job (managed LWCR). Si la firma cambio y el
# requirement guardado quedo viejo, launchd mata el proceso al instante con
# Launch Constraint Violation y la app no arranca sola.
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "==> Desregistrando el job anterior..."
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    # bootout es asincrono; esperar a que el dominio lo suelte de verdad.
    for _ in $(seq 1 20); do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
        sleep 0.5
    done
fi

echo "==> Registrando el job..."
launchctl bootstrap "$DOMAIN" "$PLIST"

sleep 2
if pgrep -f "PodsMute.app/Contents/MacOS/PodsMute" >/dev/null; then
    echo "==> Listo. PodsMute corriendo (pid $(pgrep -f 'PodsMute.app/Contents/MacOS/PodsMute' | head -1))."
    echo "    Logs: $LOG"
else
    echo "==> ATENCION: el job quedo registrado pero el proceso no esta corriendo."
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -iE "state|last exit" || true
    echo ""
    echo "    Si ves OS_REASON_CODESIGNING / Launch Constraint Violation, la firma"
    echo "    del binario cambio: recompila con ./build-clt.sh y volve a correr este script."
    exit 1
fi
