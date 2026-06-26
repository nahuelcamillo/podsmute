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

### 10. Stealth Mute — `AudioBridge` + `MuteCoordinator`

**Problema**: mutear con el flag HAL (`kAudioDevicePropertyMute`) es detectable: Chrome
lo refleja en `MediaStreamTrack.muted` y Meet muestra "El sistema silenció el micrófono"
(y en mutes largos auto-mutea sin auto-desmutear). Bajar el volumen de entrada a 0 no
sirve con AirPods (el modo HFP lo ignora).

**Solución**: un mic virtual. `AudioBridge` captura el **default input** (AirPods) y lo
reproduce en **BlackHole**; la app de meeting captura de BlackHole. Al mutear, el bridge
deja de reenviar → la app recibe silencio **sin ningún flag de mute** → indetectable.
Validado en Meet real (jun 2026).

- **Activación automática**: el bridge comparte el ciclo de vida del armado del gesto —
  `MicUsageMonitor` detecta captura externa → sube; nadie captura → baja (los AirPods no
  quedan en HFP fuera de llamadas).
- **`MuteCoordinator`** es el punto único de mute (stem / atajo / menú). Con bridge
  corriendo togglea `bridge.muted`; sin bridge, flag HAL clásico (fallback automático,
  también si BlackHole no está instalado).
- **Defensa anti-bypass**: si otro proceso captura un device real directamente (no
  BlackHole — p.ej. Zoom con los AirPods como mic), el mute del bridge no lo silencia;
  el coordinator detecta eso vía `kAudioProcessPropertyDevices` (scope input) y aplica
  **también** el flag HAL. Preferimos que Meet "vea" el mute antes que quedar audible
  creyéndose muteado. Se re-evalúa si cambia el set de devices capturados (poll 1s).
- **Sincronización del mute por proceso**: cada cambio llama
  `AVAudioApplication.setInputMuted` para que el estado que el sistema le atribuye al
  proceso siga al nuestro. Dos motivos: el stem togglea desde el estado que el sistema
  cree (sin esto, mute por atajo + press del stem quedaban fuera de fase), y con bridge
  el process-mute silencia nuestra propia captura (capa extra de silencio real). El
  `setInputMuted` programático NO dispara el banner, pero SÍ ecoa en nuestro handler del
  gesto: el AppDelegate ignora ecos (estado igual al actual).
- **Robustez**: restart automático ante `AVAudioEngineConfigurationChange` (AirPods se
  van a mitad de llamada → sigue con el nuevo default input); guard anti-loop si el
  default input ES BlackHole (no bridgear el device contra sí mismo).
- **Configuración**: Preferences → "Stealth Mute" (checkbox, default on; muestra si
  BlackHole está instalado o guía a instalarlo — `brew install blackhole-2ch` o
  existential.audio/blackhole). El menú de la barra muestra "Stealth mute: active"
  mientras el bridge corre. En la app de meeting hay que elegir **BlackHole 2ch** como
  micrófono una vez por app.
- **Debug**: `kill -USR2 <pid>` togglea el mute como si fuera el atajo (sin teclado ni
  AirPods).
- Detalles de formato: tap con `format: nil` + `AVAudioConverter` lazy (el formato HFP
  real solo se conoce con el primer buffer); solo se pinea el engine de PLAYBACK a
  BlackHole con `auAudioUnit.setDeviceID` (pinear el capture da -10851; captura siempre
  del default input).

## Build (sin Xcode)

```bash
./build-clt.sh        # compila con swiftc y arma el .app (solo Command Line Tools)
```

### Firma de código y el permiso de Accesibilidad

`build-clt.sh` firma con una identidad de code-signing **estable** si existe en el llavero
(`PodsMute Self-Signed`); si no, cae a firma **ad-hoc** con un warning.

Esto importa para el BannerKiller (sección 9): macOS identifica la app ante TCC por su
*designated requirement*. Con firma **ad-hoc** ese requirement es el **cdhash** (el hash del
binario), que cambia cada vez que recompilás con cambios de código → TCC deja de reconocer
la app → **te vuelve a pedir Accesibilidad en cada build**. Con la identidad estable el
requirement pasa a ser `identifier "com.podsmute.app" and certificate leaf = H"…"`,
constante entre rebuilds → **el permiso sobrevive**.

Crear la identidad (una sola vez; no requiere cuenta de Apple Developer):

```bash
./tools/make-signing-cert.sh   # genera un cert autofirmado y lo importa al llavero
./build-clt.sh                 # recompila firmando con esa identidad
# Otorgá Accesibilidad UNA última vez (el requirement cambió respecto del ad-hoc previo)
```

Verificación: `codesign -d -r- build/PodsMute.app` debe mostrar
`designated => identifier "com.podsmute.app" and certificate leaf = H"…"` (no `cdhash …`).

## Arranque automático

LaunchAgent en `~/Library/LaunchAgents/com.podsmute.app.plist` (RunAtLoad, apunta al
binario en `build/`). Logs en `~/Library/Logs/PodsMute.log`.

```bash
launchctl unload ~/Library/LaunchAgents/com.podsmute.app.plist   # desactivar
launchctl load   ~/Library/LaunchAgents/com.podsmute.app.plist   # activar
```

## Herramientas de diagnóstico (`tools/`)

- `audioctl` — CLI de CoreAudio: `list`, `set-input <substr>`, `mute <on|off|status>`,
  `running`, `inputvol [0..1]`, `procs` (qué procesos capturan y de qué device).
- `winls` / `winwatch` — listan/observan ventanas en pantalla (se usaron para ubicar el banner).
- `mic-diagnostic.html` — página getUserMedia que muestra `track.muted`/eventos/medidor
  (servir con `python3 -m http.server`); con ella se determinó qué detecta Chrome.

## Permisos necesarios

- **Micrófono**: para el tap del gesto y el mute por HAL.
- **Accesibilidad**: para el BannerKiller.
- **Bluetooth**: solo para mostrar el estado de conexión de los AirPods.
