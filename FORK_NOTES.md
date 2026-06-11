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

### 5. Feedback audible distintivo — `ToneService`
- Tono sintético (sin archivos) que se suma al tono nativo del sistema para
  distinguir la acción de oído: **mute = grave descendente** (C5→F4), **unmute =
  agudo ascendente** (E5→B5). Registro + dirección lo hacen inconfundible.
- Engine de output on-demand (se detiene tras ~1.5s de inactividad).
- Opt-out vía `AppSettings.muteToneEnabled` (toggle en el menú).

### 6. Entry point AppKit + ícono — `PodsMuteApp` / `StatusBarController`
- Entry point reescrito de SwiftUI `App`/`Settings` a **AppKit puro**
  (`NSApplication` + `setActivationPolicy(.accessory)`): la combinación SwiftUI
  `Settings`-only no registraba bien el NSStatusItem.
- Ícono de barra: de un ícono dibujado a mano (que rendía con ancho 0 en macOS 26)
  a un **SF Symbol template** (`mic.fill` / `mic.slash.fill`).
- **Pendiente conocido**: en MacBooks con notch + barra llena, macOS clava el item
  nuevo detrás del notch y no lo reubica → el ícono puede no verse. Mitigación: los
  hotkeys globales (abajo) permiten operar sin el ícono.

### 7. Atajos de teclado globales — `HotKeyService`
- Carbon `RegisterEventHotKey` (sin permiso de Accesibilidad, consume el combo).
- Defaults: `⌥⌘M` = toggle mute (por CoreAudio directo → **no dispara el banner**,
  funciona sin AirPods); `⌥⌘S` = toggle del tono (suena al activar, silencio al desactivar).
- **Configurables** desde la ventana de Preferencias (ver abajo). Al cambiar un atajo,
  `AppSettings` postea `.podsMuteShortcutsChanged` y `AppDelegate` re-registra (`unregisterAll`).

### 8. Preferencias — `AppSettings` + ventana
- `AppSettings`: singleton sobre `UserDefaults`, centralizado. Claves: `muteToneEnabled`,
  `muteShortcut`, `toggleSoundShortcut`, `bannerKillerEnabled`, `toneVolume`. Nombrado
  `AppSettings` (no `Settings`) para no chocar con `SwiftUI.Settings`. Postea
  `.podsMuteToneEnabledChanged` (sync de UI) y `.podsMuteShortcutsChanged` (re-registro).
- `Shortcut`: modelo (keyCode + modifiers Carbon) con conversión Cocoa↔Carbon,
  `displayString` (⌥⌘M) y serialización a UserDefaults. keyCode es común a NSEvent y Carbon.
- `ShortcutRecorderView`: control "click para grabar" — captura el próximo keyDown con
  `addLocalMonitorForEvents`, Esc cancela, × limpia. Requiere ≥1 modificador (cmd/opt/ctrl).
- `PreferencesWindowController`: ventana AppKit (sin xib). Como la app es `.accessory`,
  pasa a `.regular` mientras la ventana está abierta (para recibir foco de teclado) y
  vuelve a `.accessory` al cerrar. Abrir desde el menú → "Preferences…" (⌘,). Secciones:
  Keyboard Shortcuts (2 grabadores), Audio Cue (checkbox + volumen con íconos de altavoz,
  atenuado cuando el cue está off, preview al soltar el slider), System Banner (checkbox).
- El toggle de sonido está en el menú Y en la ventana: se sincronizan en vivo vía
  `.podsMuteToneEnabledChanged` (menú, checkbox y atajo siempre alineados).
- **Volumen del cue**: `ToneService` usa amplitude base 0.5 (headroom) y escala con
  `mainMixerNode.outputVolume = toneVolume` (default 0.44 ≈ el volumen validado original).

### Nota de arranque (bug fix importante)
`BluetoothManager` consultaba IOBluetooth **síncrono en el hilo principal** en su init.
La primera init del `IOBluetoothCoreBluetoothCoordinator` bloquea en un semáforo bajo el
contexto del LaunchAgent (CoreBluetooth no listo) → la app **se colgaba al iniciar sesión**.
Fix: todas las llamadas IOBluetooth corren en una cola serial de fondo (`btQueue`), los
resultados se publican en main. `ToneService` también crea su `AVAudioEngine` de forma
lazy (no tocar audio durante el launch). Diagnóstico: `sample <pid>` mostró el stack
bloqueado en `IOBluetoothDevice.pairedDevices` → `dispatch_semaphore_wait`.

### 9. Banner del sistema — `BannerKiller`
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
