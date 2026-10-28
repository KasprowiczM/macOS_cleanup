[🇺🇸 EN](README.md) | [🇵🇱 PL](README.pl.md) | [🇪🇸 ES](README.es.md) | [🇫🇷 FR](README.fr.md) | [🇩🇪 DE](README.de.md) | [🇮🇹 IT](README.it.md) | [🇵🇹 PT](README.pt.md)

---

<p align="center">
  <img src="assets/macos-cleanup-logo.png" alt="macOS Cleanup Logo" width="350" />
</p>

# macOS Cleanup — Limpiador de Sistema Profesional

> **Herramienta profesional de limpieza para macOS** — más segura que las aplicaciones comerciales, totalmente transparente, con control total del usuario sobre lo que se elimina.

<p align="center">
  <img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="CI Status" />
  <img src="https://img.shields.io/badge/macOS-10.15%2B-blue.svg" alt="macOS Version" />
  <img src="https://img.shields.io/badge/Bash-3.2%2B-lightgrey.svg" alt="Bash Version" />
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License" />
</p>

## ¿Qué es este proyecto?

`cleanup_all.sh` es un script bash diseñado para usuarios avanzados de macOS que:

- **Analiza** el sistema e identifica qué se puede eliminar de forma segura
- **Informa** sobre las consecuencias de cada operación antes de ejecutarla
- **Espera su consentimiento** — la respuesta predeterminada es siempre NO
- **Mueve los datos del usuario a cuarentena** en los modos de limpieza, por lo que es posible deshacer los cambios
- **Nunca toca** datos de correo, contraseñas, cookies, perfiles de navegador o documentos

## Requisitos

- macOS 10.15 Catalina o más reciente (incluyendo Sonoma, Sequoia, macOS 26.x)
- bash 3.2+ (preinstalado en macOS)
- Python 3.10+ para herramientas auxiliares `dev-sync/` y análisis seguro de `plan.json` en `apply --from-plan`
- Opcional: `bc` (para cálculos de tamaño), `mdfind` (Spotlight, preinstalado)

## Instalación

### Prueba Rápida — Instalador de una línea

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/KasprowiczM/macOS_cleanup/main/install.sh)"
```

El instalador **solo clona el repositorio e imprime los siguientes pasos** — no elimina nada ni inicia la limpieza. Se instala en `~/Dev_Env/macOS_cleanup` por defecto (cámbielo vía `MACOS_CLEANUP_DIR=...`). ¿Prefiere revisar el código primero? Descargue e inspeccione [`install.sh`](install.sh) antes de ejecutarlo.

### Instalación Manual

```bash
git clone https://github.com/KasprowiczM/macOS_cleanup.git ~/Dev_Env/macOS_cleanup
cd ~/Dev_Env/macOS_cleanup
chmod +x cleanup_all.sh
```

## Uso

### 1. Primera Ejecución Recomendada — Análisis (dry-run)

```bash
bash cleanup_all.sh
```

El script analizará su sistema, le mostrará qué se puede limpiar y le preguntará si desea proceder. **Nada se elimina sin su consentimiento.**

### 2. Limpieza Interactiva Completa

```bash
bash cleanup_all.sh --interactive
```

Recorre cada categoría, explicando qué es, las consecuencias de la eliminación y solicita su permiso. La limpieza real predeterminada funciona en modo `--quarantine`: las rutas del usuario se mueven a `~/Library/Application Support/macOS_cleanup/quarantine` en lugar de eliminarse de inmediato.

Si desea liberar espacio permanentemente de inmediato después del análisis, ejecute el modo permanente:

```bash
bash cleanup_all.sh --interactive --permanent
```

### 3. Limpieza Automática de Elementos Seguros

```bash
bash cleanup_all.sh --auto-safe
```

Por defecto, esto solo pone en cuarentena los cachés de aplicaciones explícitamente conocidos y de bajo riesgo. Los elementos generales de nivel superior en `~/Library/Caches` se informan para decisión del usuario porque podrían incluir grandes cachés fuera de línea que las aplicaciones tendrían que volver a descargar. Los archivos temporales y las rutas fuera de `$HOME` requieren el modo `--permanent` porque no hay forma de deshacer los cambios desde la cuarentena para ellos:

```bash
bash cleanup_all.sh --auto-safe --permanent
```

Todo lo demás se informa para su decisión.

### 4. Categoría Específica

```bash
bash cleanup_all.sh --interactive --category dev
bash cleanup_all.sh --dry-run --category user-caches
bash cleanup_all.sh --interactive --category time-machine
```

### 5. Analizar / planificar / aplicar

```bash
# Alias legible para flujos de trabajo de agentes/operadores
bash cleanup_all.sh analyze

# Análisis + plan estructural JSON
bash cleanup_all.sh plan

# Ejecutar el plan: solo SAFE por defecto
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json

# Simular la ejecución del plan
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run
```

`plan.json` contiene operaciones con `id`, ruta o comando, categoría, clase `SAFE`/`REVIEW`/`DANGEROUS`, tamaño estimado, descripción de las consecuencias y recomendación. `apply --from-plan` nunca ejecuta `DANGEROUS`; `REVIEW` se omite a menos que añada `--include-review` y pase por la confirmación interactiva.

### 6. Modo No Interactivo (CI/Automatización)

```bash
# Análisis sin preguntas
bash cleanup_all.sh --dry-run --non-interactive

# Limpieza segura automática sin confirmación manual (solo elementos explícitamente seguros)
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Recuperación real de espacio en automatización: solo después de un consciente --permanent
bash cleanup_all.sh --auto-safe --permanent --non-interactive --yes

# Ejecutar una categoría específica sin confirmaciones
bash cleanup_all.sh --dry-run --non-interactive --category app-leftovers
```

`--non-interactive` ejecuta el script sin leer la entrada de TTY.
Por seguridad, cada pregunta se trata como `no` por defecto.
`--yes` confirma solo las operaciones de bajo riesgo; las categorías medias/altas requieren el modo interactivo.

### 7. Con Exclusión de Ruta

```bash
bash cleanup_all.sh --interactive --exclude "$HOME/Library/Caches/myapp"
```

### 8. Cuarentena, Restauración y Purga

```bash
# Listar ejecuciones guardadas en cuarentena
bash cleanup_all.sh --list-quarantine

# Restaurar la última ejecución o un manifiesto específico
bash cleanup_all.sh --restore latest
bash cleanup_all.sh --restore reports/restore_<run_id>.tsv

# Previsualizar eliminación permanente de cuarentena
bash cleanup_all.sh --purge-quarantine latest

# Liberar realmente el espacio ocupado por la cuarentena
bash cleanup_all.sh --purge-quarantine latest --apply

# Purgar ejecuciones anteriores al período de retención
bash cleanup_all.sh --purge-quarantine expired --retention-days 30 --apply
```

La cuarentena proporciona la opción de deshacer los cambios, pero no libera espacio en disco por sí misma. Solo se recupera espacio después de `--permanent` o de un subsiguiente `--purge-quarantine ... --apply`.

### 9. Eliminar registros e informes antiguos (`--prune-artifacts`)

```bash
bash cleanup_all.sh --prune-artifacts
```

Analyze, list, plan y dry-run nunca eliminan registros ni diarios. La retención de artefactos es solo este comando explícito. La antigüedad la controla `ARTIFACT_RETENTION_DAYS` (0 desactiva).

### 10. Salida JSON — Resultados legibles por máquina (`--json`)

```bash
# Salida analítica (dry-run) en formato JSON por stdout
bash cleanup_all.sh --dry-run --non-interactive --json --category dev

# Combinar con un pipe (la salida humana va a stderr)
bash cleanup_all.sh plan --json --non-interactive 2>/dev/null | jq .counters

# Guardar JSON en un archivo y omitir el informe Markdown
bash cleanup_all.sh --dry-run --non-interactive --json --category trash 2>/dev/null > summary.json
```

La bandera `--json` redirige toda la salida legible (banners, secciones, resúmenes) a **stderr** y emite un solo objeto JSON a **stdout** al final de la ejecución. El objeto contiene:

| Campo | Descripción |
|-------|-------------|
| `mode` | Modo de ejecución (`dry-run`, `plan`, `apply-plan`, etc.) |
| `dry_run` | `true` / `false` |
| `categories` | Matriz de categorías activas |
| `counters` | `would_free_bytes`, `cleaned_bytes`, `quarantined_bytes`, `skipped_items`, `user_decisions_needed` |
| `plan` | Contadores para operaciones `SAFE`/`REVIEW`/`DANGEROUS` y bytes |
| `artifacts` | Rutas de `report`, `plan`, `journal`, `restore_manifest` |
| `warnings` | Número de elementos omitidos |
| `user_decisions` | Lista de descripciones de elementos que requieren una decisión |

La bandera funciona con cada modo (`dry-run`, `plan`, `apply`, `--auto-safe`, etc.) y es segura para `--non-interactive` y CI. No cambia ningún comportamiento si no se proporciona.

## Categorías Disponibles

| Categoría | Contenido |
|-----------|-----------|
| `trash` | Contenido de ~/.Trash |
| `system` | Cachés del sistema, archivos viejos /tmp y /private/tmp |
| `user-caches` | ~/Library/Caches (cachés de aplicaciones de usuario) |
| `logs` | Registros antiguos del sistema y de aplicaciones |
| `app-leftovers` | Informe heurístico de restos; sin eliminación automática por defecto |
| `dev` | Xcode DerivedData, simuladores, cachés de npm/pip/brew/docker |
| `time-machine` | Instantáneas locales de TM + copias de seguridad de iOS |
| `large-files` | Archivos viejos DMG/PKG/ISO en ~/Downloads |

## Modelo de Seguridad

### Filosofía: Consentimiento Informado

El script opera sobre un modelo de **consentimiento informado**:

```
Analizar → Mostrar resultados → Explicar consecuencias → Advertencias → Esperar consentimiento → Actuar
```

El lenguaje objetivo de UX/DX describe este flujo como **analizar → planificar → aplicar**:

- `analyze` — dry-run sin mutación, ej., `bash cleanup_all.sh --dry-run`
- `plan` — informe Markdown, journal JSONL y una lista de elementos que requieren una decisión
- `apply` — acción real tras el consentimiento: `apply --from-plan`, `--interactive`, `--auto-safe`, o `--purge-quarantine ... --apply`

Modelo detallado para operadores y agentes: `docs/ux_dx_safety_model.md`.

### Lo que NUNCA se Toca

<!-- BEGIN NEVER_TOUCH_PATHS -->
- `~/Library/Mail`
- `~/Library/Containers/com.apple.mail`
- `~/Library/Keychains`
- `/Library/Keychains`
- `/System/Library/Keychains`
- `~/Library/Application Support/1Password`
- `~/Library/Application Support/1Password 7`
- `~/Library/Application Support/com.agilebits`
- `~/Library/Application Support/Bitwarden`
- `~/Library/Application Support/LastPass`
- `~/Library/Application Support/Dashlane`
- `~/Library/Application Support/Enpass`
- `~/Library/Application Support/Keybase`
- `~/Library/Application Support/macOS_cleanup`
- `~/Library/Caches/com.1password.1password`
- `~/Library/Caches/com.agilebits.onepassword7`
- `~/Library/Caches/com.bitwarden.desktop`
- `~/Library/Caches/com.lastpass.LastPass`
- `~/Library/Caches/com.dashlane.Dashlane`
- `~/Library/Caches/in.sinew.Enpass-Desktop`
- `~/Documents`
- `~/Desktop`
- `~/Pictures/Photos Library.photoslibrary`
- `~/Pictures/Photos Library`
- `~/Music/Music/Music Library.musiclibrary`
- `~/Music/Music Library.musiclibrary`
- `~/Movies`
- `~/Library/Messages`
- `~/Library/Calendars`
- `~/Library/Application Support/AddressBook`
- `~/Library/Mobile Documents`
- `~/Library/CloudStorage`
- `~/Dropbox`
- `~/OneDrive`
- `~/Google Drive`
- `~/Library/Application Support/Google/DriveFS`
- `~/Library/Application Support/Google/Chrome`
- `~/Library/Application Support/Firefox`
- `~/Library/Application Support/Microsoft Edge`
- `~/Library/Application Support/BraveSoftware`
- `~/Library/Application Support/Opera`
- `~/Library/Application Support/Vivaldi`
- `~/Library/Safari`
- `~/Library/MobileDevice/Provisioning Profiles`
- `~/Library/Keychains`
- `~/Developer`
- `~/Projects`
- `~/src`
- `~/code`
- `~/repos`
- `~/.ssh`
- `~/.gnupg`
- `~/.aws/credentials`
- `~/.aws/config`
- `~/.gitconfig`
- `~/.git-credentials`
- `~/.config`
- `~/.kube`
- `~/.docker`
- `~/.netrc`
- `~/.zshrc`
- `~/.zprofile`
- `~/.zsh_history`
- `~/.bash_profile`
- `~/.bashrc`
- `~/.bash_history`
- `~/.profile`
- `~/.npmrc`
- `~/.config/gh`
<!-- END NEVER_TOUCH_PATHS -->

### Niveles de Seguridad de Reglas

- `SAFE` — artefactos reproducibles, ej., cachés de aplicaciones precisamente conocidos; puede entrar en `--auto-safe`, y aún se revisa en filtros de seguridad
- `REVIEW` — requiere un plan y decisión del usuario, ej., cachés generales, logs, artefactos de compilación, backups de iOS
- `DANGEROUS` — datos de usuario, identidad, perfiles, correo, contraseñas; no se borra automáticamente

El archivo actual `cleanup_rules.yaml` mantiene los valores técnicos `safe`, `ask`, `never`. La asociación UX/DX corresponde a `SAFE`, `REVIEW`, `DANGEROUS`.

### Registro y Reversión (Rollback)

Cada informe guarda un resumen para máquina del plan en `reports/journal_*.jsonl` (`report_generated`, `category_total`). Las operaciones reales `safe_remove()` añaden eventos de ejecución, ej., `quarantined`, `deleted`, `skipped_non_user_scope`. Comandos nativos controlados como `brew cleanup`, `docker system prune`, `xcrun simctl delete unavailable`, y `tmutil deletelocalsnapshots` añaden eventos `native_command` ya que no tienen la reversión de la cuarentena. La cuarentena también genera `reports/restore_*.tsv`, utilizado por `--restore`. El proceso de restauración se niega a recuperar datos fuera de la carpeta de usuario, en rutas protegidas, a través de directorios con enlaces simbólicos, o de archivos fuera de la cuarentena.

La cuarentena es una forma de deshacer, no una copia de seguridad. Antes de la primera limpieza real, el usuario aún debería tener una copia de seguridad reciente del sistema. El correo y los perfiles de los navegadores se manejan únicamente como pautas: los cachés podrían ser informados, pero los datos de las cuentas, las sesiones, las cookies, los marcadores y los almacenes de mensajes locales quedan fuera de la limpieza automática.

## Estructura del Proyecto

```
macOS_cleanup/
├── cleanup_all.sh          # Script principal — punto de entrada
├── cleanup_rules.yaml      # Base de conocimientos: reglas por aplicación
├── config/
│   └── defaults.sh         # Configuración por defecto, umbrales de edad, rutas protegidas
├── lib/
│   ├── common.sh           # Logging, formato, safe_remove(), protección de rutas
│   ├── policy.sh           # Analizador de políticas YAML y mapeo SAFE/REVIEW/DANGEROUS
│   ├── analyzer.sh         # Análisis del sistema (funciones analyze_*)
│   ├── cleaner.sh          # Motor de limpieza (funciones clean_*)
│   ├── planner.sh          # plan.json y apply --from-plan
│   ├── interactive.sh      # Avisos y confirmaciones de usuario
│   └── reporter.sh         # Generador de informes en Markdown
├── docs/
│   ├── rules_design.md     # Documentación de estructura de reglas
│   └── ux_dx_safety_model.md # Modelo SAFE/REVIEW/DANGEROUS y analyze/plan/apply
├── tests/                  # Escenarios de prueba
└── AGENTS.md               # El papel de los agentes IA en el proyecto
```

## Informes y Registros

Después de cada ejecución, el script genera:

- **Log**: `logs/cleanup_YYYY-MM-DD_HHMMSS_PID.log` — diario completo de operaciones
- **Informe**: `reports/report_YYYY-MM-DD_HHMMSS_PID.md` — Resumen en Markdown
- **Plan**: `reports/plan_YYYY-MM-DD_HHMMSS_PID.json` — plan estructural `SAFE`/`REVIEW`/`DANGEROUS`
- **Registro**: `reports/journal_YYYY-MM-DD_HHMMSS_PID.jsonl` — plan automático y registro de auditoría
- **Manifiesto de restauración**: `reports/restore_YYYY-MM-DD_HHMMSS_PID.tsv` — rutas necesarias para deshacer con la cuarentena

```bash
# Abrir el último informe
open reports/$(ls -t reports/ | head -1)
```

## Ampliación y Configuración

### Añadir una Nueva Aplicación a la Base de Reglas

Edita `cleanup_rules.yaml` y añade una entrada siguiendo este esquema:

```yaml
- name: "App Name"
  bundle_ids:
    - "com.vendor.appname"
  type: dev-tool   # browser|mail|dev-tool|media-editor|system|...
  paths:
    - path: "~/Library/Caches/com.vendor.appname"
      type: cache
      safety: ask   # safe | ask | never
      notes: "Descripción de qué es esto y si es seguro"
```

### Cambio de Umbrales de Antigüedad

Edita `config/defaults.sh`:

```bash
LOG_MAX_AGE_DAYS=30       # Logs de más de N días
TMP_MAX_AGE_HOURS=24      # Archivos tmp de más de N horas
DMG_MAX_AGE_DAYS=30       # DMG/PKG en ~/Downloads
```

## Aviso Legal

> **Usa este script bajo tu propia responsabilidad.** El script está diseñado teniendo en cuenta la seguridad y siempre pregunta antes de eliminar, pero ningún software está libre de errores. Asegúrate de tener una copia de seguridad reciente antes de ejecutarlo en un modo diferente a dry-run por primera vez.

---

Proyecto: `macOS_cleanup` | Versión: 2.1.0 | Licencia: MIT
