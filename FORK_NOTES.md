# Fork notes (nahuelcamillo)

Fork de [cyanicr/podsmute](https://github.com/cyanicr/podsmute) adaptado para usar el
mute por gesto del stem de los **AirPods Pro 2** en **macOS 26 (Tahoe)**, con foco en
**presentaciones**: que el mute funcione system-wide (Slack, Meet, etc.) y que **nada
se filtre a los participantes** durante un screen share.

## Qué cambió respecto al upstream

El upstream se apoya en notificaciones Darwin de `audioaccessoryd`
(`com.apple.audioaccessoryd.MuteState`). **En macOS 26 esas notificaciones ya no se
emiten**, así que el gesto nunca se detectaba. Este fork reescribe la detección y suma
el manejo del banner del sistema.

### 1. Detección del gesto — `MuteGestureService`
- Usa la API oficial `AVAudioApplication.setInputMuteStateChangeHandler` (macOS 14+).
- El handler **debe** devolver `true`: devolver `false` produce el toast
  "Cannot Control Mic with AirPods Pro" y se pierden los tonos de confirmación.
- El gesto solo se entrega a procesos con **input de audio activo**, así que el servicio
  mantiene un tap silencioso sobre el micrófono mientras está armado.

### 2. Mute system-wide — `AudioMuteController`
- `kAudioDevicePropertyMute` por CoreAudio HAL sobre el input por defecto.
- Re-resuelve el device en cada `setMute` (los IDs cambian al reconectar hardware).

### 3. Armado inteligente — `MicUsageMonitor`
- Sondea los process objects de CoreAudio (`kAudioProcessPropertyIsRunningInput`) y
  **arma el gesto solo cuando otra app está usando el micrófono** (o sea, en una llamada).
- Beneficio: fuera de llamadas los AirPods no quedan en modo HFP (la música mantiene
  calidad y el stem conserva play/pausa), y no hay punto naranja permanente.

### 4. Feedback propio invisible en captura — `MuteHUD`
- HUD estilo "bezel de volumen" con `NSWindow.sharingType = .none`: lo ves vos, **no
  aparece en screen share** (reemplaza el popover original, que sí se filtraba).

### 5. Banner del sistema — `BannerKiller`
El banner "Microphone On/Off" lo postea `cloudpaird`
(`com.apple.MuteControlUserNotifications`) y **se filtra a los participantes al compartir
pantalla completa**. No es suprimible por configuración (ignora Focus, no aparece en
Ajustes, y editar `com.apple.ncprefs` no tiene efecto).
- Solución: vía Accessibility API, al dispararse el gesto se hace un *burst* de scans;
  cuando aparece el `AXNotificationCenterAlert` se mueve **toda la ventana de
  Notification Center fuera de pantalla** y se restaura cuando el banner muere (~1.2s).
- La acción AX "Close" del banner es un **no-op** (el banner vive ~1.2s igual); por eso
  movemos la ventana.
- Trade-off: queda un *flash* negro muy breve donde estaba el overlay. Mover solo el
  recuadro del banner no sirve (NC lo reposiciona).
- **Requiere permiso de Accesibilidad** para PodsMute.

## Build (sin Xcode)

```bash
./build-clt.sh        # compila con swiftc y arma el .app (solo Command Line Tools)
```

El permiso de Accesibilidad sobrevive a las recompilaciones (macOS lo asocia a la ruta
+ bundle id), así que no hay que re-otorgarlo en cada build.

## Arranque automático

LaunchAgent en `~/Library/LaunchAgents/com.podsmute.app.plist` (RunAtLoad, apunta al
binario en `build/`). Logs en `~/Library/Logs/PodsMute.log`.

```bash
launchctl unload ~/Library/LaunchAgents/com.podsmute.app.plist   # desactivar
launchctl load   ~/Library/LaunchAgents/com.podsmute.app.plist   # activar
```

## Herramientas de diagnóstico (`tools/`)

- `audioctl` — CLI de CoreAudio: `list`, `set-input <substr>`, `mute <on|off|status>`, `running`.
- `winls` / `winwatch` — listan/observan ventanas en pantalla (se usaron para ubicar el banner).

## Permisos necesarios

- **Micrófono**: para el tap del gesto y el mute por HAL.
- **Accesibilidad**: para el BannerKiller.
- **Bluetooth**: solo para mostrar el estado de conexión de los AirPods.
