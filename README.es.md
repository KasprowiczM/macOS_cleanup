[EN](README.md) | [PL](README.pl.md) | [ES](README.es.md) | [FR](README.fr.md) | [DE](README.de.md) | [IT](README.it.md) | [PT](README.pt.md)

<p align="center">
  <a href="https://macos-cleanup.64bit.site/"><img src="assets/brand-banner.svg" alt="macOS Cleanup" width="640" /></a>
</p>

# macOS Cleanup

**Versión 4.0.4** · Mac con Apple Silicon · macOS 11 o posterior · [Sitio web](https://macos-cleanup.64bit.site/) · [Soporte](https://macos-cleanup.64bit.site/support) · [Licencia MIT](LICENSE) · [Cambios](CHANGELOG.md)

Una herramienta local para limpiar el disco con cuidado en macOS. Primero mide, te muestra un plan y actúa solo sobre lo que apruebes. La mayoría de las eliminaciones van a una carpeta de cuarentena desde la que puedes restaurarlas. Tiene una interfaz de terminal y un modo de línea de comandos sencillo, y nunca usa `sudo`.

## Qué limpia

Cada categoría tiene un nivel (tier). El nivel decide cómo la trata la herramienta.

**Regenerables (regenerable).** El propietario de los datos los reconstruye. «Limpieza segura» y una ejecución automática solo tocan las categorías cuyo modo es `auto`. De fábrica eso es únicamente `app-caches`; cualquier otra categoría regenerable empieza en `review`. En la pestaña Categorías (`m`) puedes pasar a `auto` una categoría regenerable que va a la cuarentena. `npm`, `yarn`, `pnpm` y `pip` ejecutan una herramienta nativa y nunca pueden ser `auto`.

| Categoría | Qué es | Deshacer |
|-----------|--------|----------|
| `app-caches` | Cachés de aplicaciones de una lista de permitidas integrada | restaurable |
| `xcode-derived` | Xcode DerivedData | restaurable |
| `npx`, `gradle`, `cocoapods`, `cargo`, `swift-pm`, `bundler`, `composer` | Cachés de compilación y de paquetes, que se eliminan moviéndolas a la cuarentena | restaurable |
| `npm`, `yarn`, `pnpm`, `pip` | Cachés de gestores de paquetes, limpiadas por la propia herramienta (`npm cache clean --force`, `yarn cache clean`, `pnpm store prune`, `pip cache purge`) | permanente |

**Revisión (review).** Costosas de reconstruir o visibles para ti. Cada una necesita tu consentimiento en la sesión. Nunca forman parte de una ejecución automática.

| Categoría | Qué es | Deshacer |
|-----------|--------|----------|
| `trash` | El contenido de la Papelera | restaurable |
| `user-caches` | Otros elementos de `~/Library/Caches` | restaurable |
| `app-caches-review` | Cachés de aplicaciones conocidas que pueden contener datos sin conexión o tardar en reconstruirse | restaurable |
| `user-logs`, `diagnostic-reports` | Registros antiguos e informes de fallos en tu carpeta personal | restaurable |
| `device-support` | Carpetas antiguas de iOS Device Support (se conserva la más reciente por plataforma) | restaurable |
| `pnpm-stale` | Datos obsoletos del almacén de pnpm | restaurable |
| `ios-backups` | Copias de seguridad de dispositivos iOS, confirmadas una a una | restaurable |
| `installers` | Archivos DMG, PKG e ISO antiguos en Descargas | restaurable |
| `system-logs`, `tmp` | Registros del sistema y archivos temporales fuera de tu carpeta personal | permanente, y solo en modo permanente |
| `simulators`, `sim-runtimes` | Simuladores no disponibles y entornos de ejecución de simulador inutilizables (`xcrun simctl`) | permanente |
| `brew`, `gem` | `brew cleanup --prune=all` y `gem cleanup`, que eliminan versiones antiguas instaladas | permanente |
| `docker` | `docker system prune -f` | permanente |
| `tm-snapshots` | Instantáneas locales de Time Machine (`tmutil`); se conserva la más reciente | permanente |

`sim-runtimes`, `docker` y `tm-snapshots` solo se ejecutan cuando las eliges en una ejecución interactiva, nunca desde «Limpieza segura» ni en una ejecución automática.

**Solo informe (report only).** Medidas y explicadas, nunca eliminadas por esta herramienta: `system-caches`, `xcode-archives`, `maven`, `android-avd`, `app-leftovers`, `browser-caches`, `browser-data`, `mail-data` y `mail-downloads`.

## Cómo te protege

- **Nada cambia hasta que lo aceptas.** Un análisis o una vista previa nunca toca tus archivos. La respuesta por defecto a cada pregunta es no.
- **Cuarentena, no borrado.** Cuando la herramienta mueve archivos por sí misma, los mueve a una carpeta de cuarentena en el mismo disco y registra lo que movió, de modo que `restore` pueda devolverlos. La cuarentena no libera espacio hasta que la purgas.
- **Los pasos permanentes están señalados.** Las limpiezas con herramientas nativas (`npm`, `yarn`, `pnpm`, `pip`, `brew`, `gem`, `docker`, `xcrun simctl`, `tmutil`) no se pueden deshacer y, por tanto, tampoco restaurar. El modo permanente también borra de forma definitiva. La interfaz y las preguntas lo indican siempre.
- **Una lista protegida que sigue protegida.** Mail, Mensajes, Calendarios, Contactos, llaveros, gestores de contraseñas, perfiles de navegador, Documentos, Escritorio, bibliotecas de Fotos, Música y Películas, iCloud y otras carpetas en la nube, claves SSH y GPG, archivos de credenciales, `~/.config`, carpetas de código fuente y árboles de trabajo de Git nunca se tocan. Tampoco el programa, los ajustes, el estado y la cuarentena de esta propia herramienta.
- **Se comprueba de nuevo justo antes de actuar.** Justo antes de eliminar un elemento, la herramienta comprueba que sigue existiendo, que es el mismo elemento que se planificó, que está dentro de las carpetas permitidas de su categoría, que no está en uso y que no es demasiado reciente si fijaste una antigüedad mínima.
- **Las ejecuciones automáticas son muy limitadas.** Están desactivadas por defecto. Cuando las activas, solo tocan las categorías cuyo modo es `auto` (de fábrica solo `app-caches`), solo a través de la cuarentena, y después purgan las ejecuciones de cuarentena cuyo periodo de conservación ha vencido. No ejecutan ninguna herramienta nativa y nunca usan el modo permanente.
- **Cifras honestas.** Los resultados muestran una estimación (la suma de los tamaños de aquello sobre lo que actuó la ejecución) y, cuando se puede medir, el cambio real del espacio libre. A menudo difieren, y la interfaz explica por qué. Los tamaños se muestran en unidades binarias: KiB, MiB, GiB.

La cuarentena es un deshacer, no una copia de seguridad. Haz una copia de seguridad actual antes de tu primera limpieza real.

## Requisitos

- Mac con Apple Silicon y macOS 11 Big Sur o posterior. El código no bloquea los Mac con Intel, pero quedan fuera del soporte oficial.
- `bash` 3.2 o posterior, que macOS incluye.
- Python 3.9 o posterior para la interfaz de terminal, para los planes (`plan` y `apply`) y para `migrate`. Si falta, ejecuta `xcode-select --install`. Sin Python, el modo de línea de comandos sencillo sigue funcionando para los demás comandos.
- Una terminal de al menos 40 columnas por 12 filas para la interfaz.
- Acceso a la red solo para instalar y para una actualización que tú inicias con `macos-cleanup update-self`. Limpiar, analizar y restaurar nunca usan la red.

## Instalación

```bash
/bin/bash -c "$(curl -fsSL https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh)"
```

El instalador descarga el paquete de la versión y su archivo `SHA256SUMS`, comprueba la suma de verificación, coloca el programa en `~/.local/share/macos-cleanup` y enlaza `~/.local/bin/macos-cleanup`. No necesita `git`, nunca usa `sudo`, nunca cambia tus ajustes, tu estado ni tu cuarentena, nunca instala la ejecución automática y nunca inicia una limpieza. Para instalar una versión concreta: `install.sh --version 4.0.4`.

Para comprobar tú mismo la descarga antes:

```bash
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.4/macos-cleanup-4.0.4.tar.gz
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.4/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Descomprime el paquete solo si la comprobación muestra `OK`. Las sumas de verificación protegen frente a una descarga dañada o incompleta. Las versiones no están firmadas criptográficamente, así que una suma de verificación obtenida del mismo lugar que el paquete no demuestra quién lo publicó. Más opciones y pasos manuales: [INSTALL.md](docs/user/INSTALL.md) (en inglés).

Si después no se encuentra `macos-cleanup`, abre una ventana de terminal nueva y comprueba que `~/.local/bin` está en tu `PATH`.

## Primera ejecución

```bash
macos-cleanup
```

En una terminal, esto abre la interfaz en el Panel. Sin terminal, un simple `macos-cleanup` es un análisis de solo lectura. Pulsa `S` para analizar. Un análisis no cambia nada. Pulsa `P` para una vista previa de lo que haría una limpieza y después `C` para limpiar las categorías seguras, o elige categorías en la pestaña Categorías y pulsa `X`.

`mac-cleanup` es el mismo comando que `macos-cleanup`, y ambos funcionan desde cualquier carpeta. Sin argumentos, cada uno abre la interfaz; `--cli` se ejecuta en modo de terminal simple. El instalador te avisa cuando otro programa de tu `PATH` responde a alguno de los dos nombres: escribir ese nombre ejecutaría entonces ese programa, no macOS Cleanup.

En texto sencillo, en su lugar:

```bash
macos-cleanup scan
```

Antes de hacer nada real, ejecuta `macos-cleanup doctor` para ver tus rutas, el espacio libre, el estado de Acceso total al disco y las instantáneas locales.

## La interfaz de terminal

Siete pestañas, a las que se llega con `1` a `7`:

| # | Pestaña | Para qué sirve |
|---|---------|----------------|
| 1 | Panel | Analizar, vista previa, limpiar. Progreso en vivo por categoría y el resultado de la última ejecución |
| 2 | Categorías | Cada categoría con su nivel, modo y tamaño. Aquí eliges qué limpiar |
| 3 | Cuarentena | Restaurar una ejecución, purgar una ejecución (escribes la última parte de su id), purgar las ejecuciones vencidas |
| 4 | Historial | Ejecuciones anteriores y sus informes. Aplicar un plan reciente |
| 5 | Ajustes | Idioma y aspecto, límites de seguridad, reglas, conservación, programación, rutas, exportar e importar |
| 6 | Diagnóstico | Comprobaciones de estado, Acceso total al disco, vista previa de la migración de la estructura |
| 7 | Ayuda | Teclas, niveles, rutas, versión |

Teclas principales: las flechas mueven, `Intro` (`Enter`) abre o confirma, `Tab` cambia de panel, `Esc` retrocede (o pregunta si detener una tarea en curso), `1` a `7` saltan a una pestaña, `?` abre la ayuda, `L` muestra el registro, `q` sale. `/` busca y `s` ordena en las listas que lo ofrecen. La línea inferior muestra siempre las teclas que funcionan en ese momento. Detalles completos: [USER_GUIDE.md](docs/user/USER_GUIDE.md) (en inglés).

## Uso sencillo desde la línea de comandos

`macos-cleanup` con un subcomando nunca abre la interfaz. Lo mismo ocurre con `--cli` y con cualquier ejecución sin terminal. Un simple `macos-cleanup` sin terminal es un análisis de solo lectura.

```bash
macos-cleanup scan                        # medir, no cambiar nada
macos-cleanup plan                        # medir y escribir un archivo de plan
macos-cleanup clean --safe                # categorías en modo auto, tras una pregunta
macos-cleanup clean --only trash,npm      # exactamente estas categorías, con una pregunta por sección
macos-cleanup quarantine list             # listar los puntos de restauración
macos-cleanup restore latest              # devolver la última ejecución
macos-cleanup quarantine purge expired --apply   # eliminar de forma permanente los puntos de restauración vencidos
macos-cleanup doctor                      # comprobar este Mac
macos-cleanup history                     # listar las ejecuciones anteriores
```

`scan`, `plan`, `quarantine list`, `history` y `doctor` son de solo lectura. `clean`, `apply`, `restore` y `quarantine purge ... --apply` cambian cosas. `quarantine purge` sin `--apply` solo muestra una vista previa. Una restauración nunca sobrescribe: un elemento cuyo lugar original está ocupado se omite y permanece en la cuarentena, y la restauración termina entonces con una advertencia (estado de salida 1), no con un error. Consulta la tabla de todos los comandos y opciones en la [guía de usuario](docs/user/USER_GUIDE.md) (en inglés).

## Dónde están los archivos

| Qué | Dónde | Se cambia con |
|-----|-------|---------------|
| Programa | `~/.local/share/macos-cleanup` | `MACOS_CLEANUP_HOME` |
| Ajustes y reglas | `~/.config/macos-cleanup` | `MACOS_CLEANUP_CONFIG_DIR` |
| Registros, informes, planes, historial | `~/.local/state/macos-cleanup` | `MACOS_CLEANUP_STATE_DIR` |
| Cuarentena (puntos de restauración) | `~/Library/Application Support/macOS_cleanup/quarantine` | `MACOS_CLEANUP_QUARANTINE_DIR` |

Los cambios deben ser rutas absolutas. La cuarentena debe estar en el mismo disco que tu carpeta personal. Actualizar sustituye solo el programa. Los ajustes, el estado y la cuarentena permanecen.

## Ejecuciones automáticas

Desactivadas por defecto, y el instalador nunca las activa. Las activas en **Ajustes**, o con:

```bash
macos-cleanup schedule install --time 10:30
macos-cleanup schedule status
macos-cleanup schedule remove
```

Esto instala un LaunchAgent de macOS (`com.github.kasprowiczm.macos-cleanup`). Una ejecución programada hace solo dos cosas: mueve a la cuarentena elementos de las categorías cuyo modo es `auto` (de fábrica solo `app-caches`) y purga las ejecuciones de cuarentena cuyo periodo de conservación ha vencido. No ejecuta ninguna herramienta nativa, nada del nivel «revisión» y nunca el modo permanente. Escribe una entrada normal en el Historial.

## Actualizar y desinstalar

Ejecuta de nuevo el instalador, o `macos-cleanup update-self`, para actualizar. La versión anterior se conserva junto al programa como `.previous`. Para eliminar la herramienta:

```bash
macos-cleanup uninstall --dry-run
macos-cleanup uninstall
```

Pregunta si quieres conservar tus ajustes y tu historial de ejecuciones, y nunca elimina la cuarentena salvo que pases `--purge-quarantine --yes`. Consulta [UNINSTALL.md](docs/user/UNINSTALL.md) (en inglés). ¿Vienes de la versión 3.x? Lee [MIGRATING_FROM_V3.md](docs/user/MIGRATING_FROM_V3.md) (en inglés).

## Privacidad

Analizar, limpiar y restaurar funcionan sin conexión; la red se usa solo para instalar y para `update-self`. La herramienta no envía a ninguna parte rutas, resultados ni datos de uso, y no tiene telemetría. Los registros, informes y planes permanecen en la carpeta de estado de tu Mac. Usa `--redact` para sustituir tu carpeta personal por `~` y omitir tu nombre de usuario y de equipo antes de compartir un informe.

## Límites y carencias conocidas

- La cuarentena no libera espacio hasta que la purgas, y las instantáneas locales pueden retener bloques borrados después. El espacio vuelve cuando macOS lo recupera.
- Los tamaños son estimaciones por exceso. No se detectan los clones de APFS ni los bloques compartidos.
- Sin Acceso total al disco, algunas carpetas no se pueden leer. El análisis se marca entonces como parcial y esos tamaños son cotas inferiores.
- Las limpiezas con herramientas nativas y el modo permanente no se pueden deshacer.
- Las categorías «solo informe» nunca se eliminan. Límpialas con sus propias herramientas.
- Las versiones se verifican con una suma de verificación, no con una firma criptográfica.
- Apple Silicon con macOS 11 o posterior es la configuración admitida. Las demás configuraciones no se han probado.

## Documentación

[Guía de usuario](docs/user/USER_GUIDE.md) · [Instalación](docs/user/INSTALL.md) · [Desinstalación](docs/user/UNINSTALL.md) · [Migrar desde 3.x](docs/user/MIGRATING_FROM_V3.md) · [Cambios](CHANGELOG.md) (todo en inglés)

## Soporte

[macos-cleanup.64bit.site/support](https://macos-cleanup.64bit.site/support)

## Licencia

[MIT](LICENSE)

> **Úsala bajo tu propio riesgo.** La herramienta está diseñada para preguntar antes de actuar y para mantener abierto el camino de vuelta, pero ningún software está libre de errores. Haz primero una copia de seguridad.
