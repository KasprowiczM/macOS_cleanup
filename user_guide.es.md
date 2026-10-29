[🇺🇸 EN](user_guide.md) | [🇵🇱 PL](user_guide.pl.md) | [🇪🇸 ES](user_guide.es.md) | [🇫🇷 FR](user_guide.fr.md) | [🇩🇪 DE](user_guide.de.md) | [🇮🇹 IT](user_guide.it.md) | [🇵🇹 PT](user_guide.pt.md)

---

# macOS Cleanup — Guía del Usuario

Este documento asume que no necesita conocer la estructura de `~/Library` ni cómo funcionan los cachés. El objetivo es recuperar espacio de forma segura sin borrar correos electrónicos, contraseñas, documentos, perfiles de navegador, proyectos y ajustes de aplicaciones.

## La Regla de Oro

No ejecute la limpieza "a ciegas". Realice siempre un análisis primero:

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Esto no borra nada. El script mostrará:

- cuánto espacio se puede recuperar potencialmente,
- qué elementos son `SAFE` (seguros),
- qué elementos requieren `REVIEW` (revisión),
- qué elementos son `DANGEROUS` (peligrosos) y no se eliminarán automáticamente.

## Clases de Riesgo

| Clase | Significado | Qué hace el script |
|-------|------------|----------------|
| `SAFE` | Datos recreables: cachés de apps, cachés de compilación, logs antiguos, tmp. | Puede borrarlos en `auto-safe` o ejecutarlos desde un plan. Por defecto, van a cuarentena para archivos de usuario. |
| `REVIEW` | Se puede recuperar espacio, pero puede haber un coste: volver a descargar, inicio más lento, pérdida de logs de diagnóstico, estado de emuladores. | Se muestra en el plan. No se borra automáticamente sin una decisión consciente. |
| `DANGEROUS` | Correo, perfiles de navegador, contraseñas, documentos, ajustes, datos de aplicaciones activas. | Solo se reporta o bloquea. Nunca se borra automáticamente. |

Si no entiende un elemento del informe, trátelo como `REVIEW` o `DANGEROUS`.

## Copia de Seguridad y Cuarentena

La limpieza real requiere una copia de seguridad reciente de Time Machine. Si el script no puede verificarla, la limpieza se bloqueará. Puede forzar la ejecución mediante:

```bash
bash cleanup_all.sh --auto-safe --allow-no-backup
```

Use esto solo si acepta conscientemente el riesgo.

La cuarentena no libera espacio inmediatamente. Por defecto, los archivos de usuario van a:

```text
~/Library/Application Support/macOS_cleanup/quarantine/<run_id>/
```

Solo recuperará espacio mediante `--permanent` o una purga posterior:

```bash
bash cleanup_all.sh --purge-quarantine latest --apply
```

Restaurar:

```bash
bash cleanup_all.sh --restore latest
```

## Flujo de Trabajo Más Seguro

### 1. Análisis

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Lea el informe en `reports/report_*.md`.

### 2. Plan JSON

```bash
bash cleanup_all.sh plan --non-interactive --no-color
```

El plan se guarda en `reports/plan_*.json`. Cada operación tiene un `id`, `risk`, `path`, `description` y `recommendation`.

### 3. Limpieza Más Segura

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes
```

Esto solo limpia cachés de apps `SAFE` explícitamente conocidos. Si no hay copia de seguridad verificada:

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes --allow-no-backup
```

### 4. Revisión Interactiva para Elementos Mayores

```bash
bash cleanup_all.sh --interactive
```

El script mostrará la categoría, el tamaño, las consecuencias y preguntará. La respuesta por defecto siempre es `no`.

## Qué se puede borrar sin grandes consecuencias

Los siguientes elementos suelen ser `SAFE`, pero aun así pueden causar un primer inicio más lento de la app:

- Caché de Slack/Teams/Discord: la app recreará los recursos web y las miniaturas.
- `Cache` y `Code Cache` de VS Code/Cursor: el editor reconstruirá la caché; los proyectos y los ajustes se mantienen.
- `Cache` estándar de Spotify: la música/podcasts se volverán a descargar.
- Caché de Zoom: no borra grabaciones de `Documents/Zoom`.
- DerivedData de Xcode: Xcode reconstruirá los proyectos desde cero.
- Caché de npm/pnpm/yarn/pip/Homebrew: las dependencias se volverán a descargar.
- Logs antiguos: pierde el historial de diagnóstico, pero no los datos de la app.
- Archivos `/tmp` antiguos: temporales, macOS suele limpiarlos él mismo.

## Qué Requiere Análisis

### `~/Library/Caches` General

El script muestra elementos de nivel superior de `~/Library/Caches` como `REVIEW`, porque no todas las cachés son baratas de recrear. Algunas apps mantienen aquí grandes datos offline, mapas, medios, modelos de IA o cachés de trabajo.

Qué comprobar:

- reconoce la app por el nombre de la carpeta,
- tiene la app datos offline,
- acepta descargar de nuevo gigabytes de datos,
- no está trabajando offline actualmente.

### JetBrains

La caché de JetBrains puede ser grande. Su borrado no elimina los proyectos, pero el IDE reconstruirá sus índices. Esto puede tardar mucho y forzar la CPU. Bórrela solo cuando tenga tiempo para la reindexación.

### Caché de Medios de Adobe

No borra proyectos de origen ni medios, pero Premiere/After Effects podrían necesitar regenerar previsualizaciones, confirmar audio/vídeo y cachés. Bórrelo solo si tiene los medios originales y acepta una apertura inicial del proyecto más lenta.

### Figma

La caché suele ser recreable, pero puede afectar a la reapertura de archivos grandes y al trabajo offline. Es preferible revisarla.

### Spotify PersistentCache

Puede implicar mayores datos de streaming/offline. El borrado podría forzar descargas de nuevo. La `Spotify Cache` normal es más segura que `PersistentCache`.

### Soporte de Dispositivos Xcode

Son símbolos de depuración para dispositivos iOS/watchOS/tvOS. Xcode los descargará de nuevo cuando conecte un dispositivo con una determinada versión de SO. Bórrelo solo si no depura dispositivos antiguos o si tiene tiempo e internet.

### Archivos de Xcode

Los archivos `.xcarchive` pueden ser necesarios para la App Store, la simbolización de bloqueos (crashes) y la recreación de compilaciones. El script solo los reporta. Bórrelos manualmente desde el Organizador de Xcode tras comprobarlos.

### Runtimes del simulador

Los runtimes que `simctl` marca como inutilizables están en un almacén gestionado por el sistema. El script nunca los borra con `rm`: en `--interactive` ejecuta `xcrun simctl runtime delete --unusable` tras su consentimiento y lo omite mientras Xcode, Simulator o xcodebuild estén en ejecución. Los planes solo los informan. Xcode puede volver a descargar un runtime. Compruebe:

```bash
xcrun simctl runtime delete --unusable --dry-run
```

### Docker

`docker system prune -f` borra imágenes, contenedores parados, redes y cachés de compilación. No borra volúmenes, pero los contenedores parados podrían contener estado que aún no ha movido a un volumen. Compruebe:

```bash
docker ps -a
docker system df
```

### Android AVD

Los emuladores de Android pueden contener estados locales de aplicaciones de prueba. Bórrelos desde Android Studio Device Manager, no mediante un `rm` manual si no está seguro.

### Maven `~/.m2/repository`

Puede contener artefactos compilados localmente que no están disponibles en internet. El script trata esto como algo que solo debe revisarse.

### Copias de seguridad de iOS

Son copias del iPhone/iPad. Bórrelas solo si tiene una copia de seguridad reciente en iCloud o una nueva en Finder.

### Snapshots locales de Time Machine

macOS los borra automáticamente cuando necesita espacio. La limpieza manual solo tiene sentido si entiende que está perdiendo puntos de restauración locales.

## Qué NO Borra el Script Automáticamente

### Apple Mail

`~/Library/Mail` y `~/Library/Containers/com.apple.mail` pueden contener mensajes, archivos adjuntos, cuentas POP, índices y archivos locales. El script solo muestra los tamaños y las áreas más grandes.

Acciones seguras:

- en Mail.app, borre los mensajes grandes,
- vacíe la Papelera y el Correo no deseado en Mail.app,
- compruebe los archivos adjuntos,
- exporte los buzones locales antes de la intervención manual.

### Navegadores

Los perfiles de Chrome/Firefox/Safari/Edge/Brave contienen cookies, sesiones, contraseñas, historial, marcadores y extensiones. El script no los borra.

Borre los datos del sitio desde la interfaz:

- Safari: Ajustes -> Privacidad -> Gestionar datos del sitio web.
- Chrome/Brave/Edge: `chrome://settings/clearBrowserData`.
- Firefox: Ajustes -> Privacidad y Seguridad -> Cookies y Datos del Sitio.

Borrar las cookies podría cerrar su sesión en los sitios web.

### Soporte de Aplicaciones y Preferencias

`~/Library/Application Support` y `~/Library/Preferences` a menudo contienen bases de datos, ajustes, licencias, proyectos locales y configuraciones. El script no borra los datos de aplicaciones activas. Los restos de aplicaciones desinstaladas solo se notifican.

## Cómo Leer `plan.json`

Ejemplo:

```json
{
  "id": "op-0007",
  "category": "app-caches",
  "risk": "SAFE",
  "action": "remove_path",
  "path": "/Users/me/Library/Caches/com.spotify.client",
  "estimated_bytes": 532000000,
  "description": "Spotify cache: streaming cache muzyki/podcastów.",
  "recommendation": "SAFE: można usunąć przez auto-safe..."
}
```

Interpretación:

- `SAFE`: se puede ejecutar mediante `apply --from-plan`.
- `REVIEW`: requiere una decisión manual.
- `DANGEROUS`: no se ejecutará.
- `native_command`: el script ejecutará una herramienta como `brew cleanup`; generalmente sin recuperación en cuarentena.
- `report_only`: solo información, sin borrado.

## Ejemplos de Decisiones

| Situación | Decisión |
|----------|---------|
| Quiere recuperar rápidamente algo de espacio sin riesgo | `--auto-safe` |
| Tiene una gran cantidad de caché de npm/pnpm e internet | limpie la categoría `dev` tras la revisión |
| Tiene un perfil de Chrome/Firefox grande | no lo borre manualmente, use la UI del navegador |
| Gran tamaño de `~/Library/Mail` | límpielo desde Mail.app, no a través del script |
| Archivos `Xcode Archives` de gran tamaño | compruebe Xcode Organizer |
| No hay copia de seguridad de Time Machine | no aplique realmente a menos que use conscientemente `--allow-no-backup` |

## Comandos Útiles

```bash
# Analizar todo
bash cleanup_all.sh --dry-run --non-interactive --no-color

# Plan JSON
bash cleanup_all.sh plan --non-interactive --no-color

# Solo caché de desarrollador
bash cleanup_all.sh --dry-run --category dev --non-interactive --no-color

# Limpieza más segura
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Interactivamente, con preguntas completas
bash cleanup_all.sh --interactive

# Simular ejecución del plan
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run --non-interactive --no-color

# Restaurar desde la cuarentena
bash cleanup_all.sh --restore latest

# Liberar espacio de la cuarentena tras la verificación
bash cleanup_all.sh --purge-quarantine latest --apply
```

## Cuándo Abortar

Aborte y no confirme la limpieza si:

- no tiene copia de seguridad,
- no entiende la ruta,
- se refiere a correo, navegadores, contraseñas, documentos o ajustes,
- se encuentra diagnosticando un fallo y necesita los logs,
- la app tiene datos offline que no desea volver a descargar.

La limpieza segura consiste en recuperar espacio a partir de datos recreables, no en borrar todo lo que es grande.
