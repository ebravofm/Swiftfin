# Fork de Swiftfin para Datapulse

Este documento describe los cambios que tiene este fork (`ebravofm/Swiftfin`, rama `feature/musicvideos-folders`) respecto a Swiftfin, por qué se hicieron, cómo se compila e instala, y qué queda sin verificar. Está escrito para quien retome el trabajo sin haber visto la conversación en que se hizo.

Todo se probó en un **Apple TV HD con tvOS 26.6** contra un servidor Jellyfin doméstico. Salvo donde se indica, los cambios de código no se pudieron compilar ni correr en local (el Mac de desarrollo tiene macOS 14, que no admite Xcode 26), así que cada cambio se valida compilando en GitHub Actions e instalando en el Apple TV.

## Objetivo

Ver los videoclips y conciertos de Jellyfin en el Apple TV de forma ordenada:

- Los videoclips **agrupados por artista**, como carpetas.
- Poder reproducir todo lo de una biblioteca o carpeta, en orden o aleatorio.
- Ver las playlists de Jellyfin.
- Títulos limpios, con el artista en una línea aparte.

Con el Swiftfin de serie esto no funciona bien: las bibliotecas de tipo *Videos musicales* se muestran planas y con las tarjetas sin imagen, no hay *Play All* ni *Shuffle*, y las playlists no aparecen.

## Resumen de cambios en la app

| Commit | Qué hace | Archivos principales |
|---|---|---|
| `09de0535`, `f43a8f25` | Las bibliotecas *Videos musicales* se navegan por carpetas (una por artista) y se piden sin recursión. | `BaseItemDto+LibraryParent.swift`, `ItemLibrary.swift` |
| `cfd43f8d` | El nombre visible de la app en tvOS pasa a *Jellyfin*. | `Swiftfin tvOS/Resources/Info.plist` |
| `66d87c61` | Pestañas *Concerts* y *Video Clips* resueltas por nombre de biblioteca, y barra de pestañas superior por defecto. | `MainTabView.swift`, `TabItem.swift`, `SwiftfinDefaults.swift` |
| `04ee460c` | Caché de `DerivedData` en el CI (ver "Compilar": ayudó poco). | `.github/workflows/ci.yml`, `fastlane/Fastfile.swift` |
| `a6a4ab2c` | Botones *Play All* y *Shuffle* y cola de reproducción propia. Ícono de micrófono en *Concerts*. | `ItemLibrary.swift`, `MainTabView.swift` |
| `4635c52a`, `1164717c` | Soporte de playlists y pestaña *Playlists*. | `CollectionType.swift`, `BaseItemDto+LibraryParent.swift`, `BaseItemDto+LibraryElement.swift`, `ItemLibrary.swift`, `MainTabView.swift` |
| `8eb27f09` | Corrige el `No Results` al volver de segundo plano. | `UserSession.swift`, `UserSessionManager.swift` |
| `81f36529` | La tarjeta de una playlist usa el póster de su primer elemento. | `ItemLibrary.swift`, `BaseItemDto+Poster.swift` |
| `96bbdf94` | El artista aparece bajo el título en las tarjetas de clips. | `BaseItemDto+PosterSubtitle.swift` |
| `d9edbcfa` | El artista aparece sobre el título en el reproductor. | `VideoPlayer+Toolbar.swift` |

(`1856a7f7` es un commit vacío para disparar el CI.)

## Detalle de cada cambio

### Bibliotecas *Videos musicales* por carpetas

Swiftfin trata las bibliotecas por su tipo de colección. Para `musicvideos` pedía solo `movie`, `musicVideo`, `series`, `video` y `boxSet`, de forma **recursiva**: Jellyfin devolvía todos los clips sin las carpetas intermedias. Y las tarjetas salían vacías.

- `isFolderCollection` ahora incluye `musicvideos`, así que la biblioteca se explora como un árbol de carpetas.
- `supportedItemTypes` de una biblioteca `musicvideos` es `[.folder, .musicVideo]`. Como ambos tipos prefieren tarjeta horizontal, la lista se dibuja horizontal, y las imágenes cargan.
- `ItemLibrary.makeBaseItemParameters` manda `recursive=false` **explícito**. Descubierto probando contra el servidor: cuando se pasan tipos de elemento y se omite `recursive`, Jellyfin lo trata como recursivo. Con `recursive=false` devuelve exactamente las carpetas de artista.

No se averiguó por qué las tarjetas verticales salían vacías con el código original; el cambio de tipos lo resolvió y no se profundizó.

### Pestañas por nombre

`TabItem.namedLibrary(libraryName:title:systemName:)` crea una pestaña que, al abrirse, busca entre las vistas del usuario (`getUserViews`) la biblioteca cuyo nombre coincide (sin distinguir mayúsculas) y muestra su lista. Si no la encuentra, muestra un error con el nombre. Ventaja: sobrevive a que la biblioteca se recree (su ID cambia).

Pestañas de tvOS, en orden: *Home, Concerts, Video Clips, Playlists, Search, Media, Settings*. Se quitaron *TV Shows* y *Movies* (siguen accesibles por *Media*). El valor por defecto de `tabBarPlacement` pasó a `.tabBar` (barra superior); la opción ya existía en *Settings → Customize → Advanced → Tab Bar → Layout*.

### Play All y Shuffle

- Una barra con los dos botones arriba de la lista de cualquier biblioteca o carpeta de tvOS (`LibraryPlayBar`, en `ItemLibrary.swift`; solo tvOS, no aparece en TV en vivo ni en la vista `Playlists`).
- Al pulsarlos se piden todos los videos bajo el elemento (`movie`, `musicVideo`, `video`, `episode`), recursivos, hasta 1000. *Play All* los ordena por artista y título; *Shuffle*, al azar. Dentro de una playlist, *Play All* conserva el orden de la lista.
- `ListMediaPlayerQueue` implementa `MediaPlayerQueue` (hasta ahora solo existía la de episodios). Calcula el elemento siguiente y el anterior a partir del que suena, y ofrece una lista para saltar. Los clips parten desde el inicio, sin retomar la posición guardada.
- Al terminar la cola, el reproductor se detiene.
- El paso automático al siguiente depende de la opción de servidor `EnableNextEpisodeAutoPlay` del usuario, que Swiftfin ya respetaba; en este servidor está activada.

### Playlists

- `CollectionType.supportedCases` acepta `.playlists`, con lo que la vista *Playlists* de Jellyfin aparece en *Media*.
- Una vista de tipo `playlists` pide solo elementos `playlist`.
- Seleccionar una playlist la abre como una carpeta (`BaseItemDto+LibraryElement.swift`).
- Al listar los elementos de una playlist **no se manda orden** (`sortBy = nil`): Jellyfin la devuelve en el orden en que fue armada, y respeta cualquier orden que se pida.
- Desde la app no se pueden crear ni editar playlists; eso se hace en Jellyfin web.

**Portada de la playlist.** Jellyfin genera como imagen de una playlist un mosaico de 4 cuadros con los pósters de varios elementos (se repiten si son pocos). Se ve mal en una tarjeta. `PlaylistCoverStore` guarda el póster del primer elemento de cada playlist, que se llena cuando se listan las playlists (`ItemLibrary.cacheCovers`), y `BaseItemDto.imageSources` lo usa antes que la imagen propia de la playlist. Si cambia el primer elemento, la portada se actualiza al volver a abrir la vista.

### Artista en tarjetas y en el reproductor

Los títulos de los clips son solo la canción, así que el artista se muestra aparte:

- En las tarjetas, `posterSubtitle(using:)` devuelve el primer artista para los elementos `musicVideo`, **sin depender del ajuste de subtítulo** de los pósters.
- En el reproductor, `TitleView` (en tvOS) muestra el artista arriba, en letra pequeña, y la canción debajo, igual que los episodios muestran la serie. Los conciertos no cambian.

### Corrección del `No Results` al volver de segundo plano

**Síntoma:** al salir de la app un rato y volver, todas las bibliotecas mostraban `No Results`. Solo se arreglaba cerrando la app por completo. No ocurría al volver de inmediato.

**Diagnóstico:**
- No era una sesión perdida: el Apple TV seguía conectado y con token válido (se vio en el servidor, el WebSocket entraba sin error, y en la red las peticiones devolvían `200 OK`).
- En la red solo se veía `GET /UserViews`, ninguna petición `/Items`: las pantallas ya abiertas no volvían a pedir nada.
- Causa: `UserSessionManager.appWillEnterForeground()` llama a `refreshCurrentSession()`, que **reconstruye la `UserSession` desde lo guardado y detiene la anterior**. `UserSession.willStop()` llama a `items.invalidate()`, que deja inutilizables los registros que mantienen las vistas existentes. Las vistas siguen apuntando a esa sesión vieja y se quedan vacías sin recargar. La raíz mantiene el mismo `id`, así que la vista no se reconstruye.

**Arreglo:** `refreshCurrentSession(keepingUnchangedSession:)`. Al volver a primer plano solo se reemplaza la sesión si el servidor, su dirección, el usuario o el token guardados **cambiaron** (`UserSession.hasSameIdentity(as:)`). El socket ya tiene su propia reconexión.

**Estado:** arreglo por lectura de código. No se sabe por qué volver de inmediato no lo disparaba (hipótesis: tvOS tarda en enviar la notificación de primer plano). **Sin verificar** en el Apple TV; ver "Pendiente".

### Límites de H.264 por modelo (Apple TV HD)

**Problema:** un concierto en 2560×1440, H.264 nivel 5.0, se reproducía con desfase y pocos fotogramas. Swiftfin declaraba al servidor que el Apple TV reproduce H.264 hasta el nivel 8.0 y sin límite de resolución, así que Jellyfin respondía `DirectPlay`. El Apple TV HD (`AppleTV5,3`, chip A8) decodifica H.264 por hardware solo hasta 1080p, y lo demás cae a software.

**Arreglo:** `PlaybackCapabilities.h264Limits` devuelve los límites según el identificador del modelo (`modelIdentifier`, leído con `uname`). Para `AppleTV5,3`: 1920×1080, nivel 4.2 y 60 fps. Los demás modelos devuelven `nil` y siguen con el perfil de antes (nivel 8.0, sin límite de resolución). `_h264BaseConditions` (en `VideoPlayerType+Shared.swift`, usado por AVPlayer y VLC) agrega las condiciones `width`, `height` y `videoFramerate` y baja el nivel cuando hay límites. Lo que los exceda lo transcodifica el servidor.

**Estado:** verificado en el Apple TV el 2026-10-23 con la build de `4d2ba929`. `uname` devuelve `AppleTV5,3` y la sesión pasa a `Transcode` con `TranscodeReasons` `VideoLevelNotSupported` y `VideoResolutionNotSupported`. El servidor transcodifica con `h264_vaapi` y `scale_vaapi=w=1920:h=1080` a unos 220 fps (7,4 veces el tiempo real). El video dejó de dar tirones, pero con VLC el audio llegaba atrasado (ver la sección siguiente).

### Segmentos MPEG-TS para VLC

**Problema:** con el concierto transcodificado y el reproductor VLC, el audio iba atrasado respecto al video, con un desfase fijo. Con AVPlayer se veía sincronizado, y el archivo original se ve bien con VLC en un PC. Los segmentos fMP4 que genera Jellyfin están sincronizados: medidos en los minutos 15 y 45, audio y video empiezan con menos de 35 ms de diferencia. Los videos que se reproducen directo no tienen el problema.

**Arreglo:** el perfil de transcodificación de VLC (`_vlcTranscodingProfiles`, en `VideoPlayerType+VLC.swift`) pide el contenedor `ts` en vez de `mp4`, así que Jellyfin entrega HLS con segmentos MPEG-TS. Simulando el `PlaybackInfo`, el servidor responde `SegmentContainer=ts` con los mismos códecs y motivos de transcodificación. El perfil aparte para VC1 y el de AVPlayer siguen en `mp4`.

**Estado:** sin probar en el Apple TV. Si el desfase sigue con TS, la alternativa es usar AVPlayer, pero la normalización de volumen solo funciona con VLC.

**Siguientes pasos previstos:** HDR y Dolby Vision (requiere activar `EnableTonemapping` en Jellyfin), subtítulos gráficos grabados en el video por el servidor, y un tope de bitrate.

## El servidor Jellyfin

Esto vive fuera de este repo, pero el comportamiento de la app depende de ello.

**Bibliotecas:**

- `Concerts`: tipo *Películas*, una carpeta por concierto con `movie.nfo` (raíz `<movie>`) y sus imágenes.
- `Videoclips`: tipo *Videos musicales*, organizada por artista:

```
Videoclips/
  <Artista>/
    folder.jpg  landscape.jpg  backdrop.jpg      (imágenes de la carpeta del artista)
    <Clip>/
      <Clip>.mp4
      <Clip>.nfo                                  (raíz <musicvideo>, con <artist>)
      <Clip>-poster.jpg  <Clip>-fanart.jpg  <Clip>-landscape.jpg
```

Reglas que salieron de pruebas:

- Una carpeta con un solo video se trata como el video mismo; por eso cada clip va en su propia subcarpeta, y así todos los artistas aparecen como carpeta.
- Con dos videos en la misma carpeta, Jellyfin ignora las imágenes.
- La carpeta del artista se llama como el `<artist>` del `.nfo`.
- Las imágenes de la carpeta del artista se escriben sin sobrescribir las existentes (otras sesiones pueden agregar clips al mismo tiempo).

**Convención de títulos** (el `<title>` del `.nfo` es lo que se ve; no se renombran carpetas):

- Videoclips: solo la canción, con la variante entre paréntesis si importa (`Manchild (Live on SNL)`, `Moonlight`, `Tyrant (feat. Jorja Smith)`). Se quitan `(Official Video)` y similares. Etiquetas de variante siempre en inglés (`Live`).
- Conciertos: una frase natural, `Artista at Evento Año` (`Dua Lipa at Tiny Desk (Home) 2020`); `Artista Live in Lugar Año` si es un concierto propio; `Título (Artista, Año)` para una película-concierto.
- Un video de unos 10 minutos o menos es videoclip; más largo, concierto.

**IDs y rutas.** Jellyfin deriva el ID de cada elemento de su ruta. Cambiar la ruta de una biblioteca cambia todos los IDs y **vacía las playlists** que los incluían (hubo que repoblar una). Renombrar una biblioteca deja el nombre viejo en memoria hasta reiniciar el servicio `jellyfin`. Por eso los títulos se cambian en el `.nfo` y no se renombran carpetas.

**Cambiar el tipo de una biblioteca no es posible** borrándola y recreándola: Jellyfin conserva la fila y los elementos en su base. Para cambiarlo hay que borrar la biblioteca, detener Jellyfin, respaldar `jellyfin.db` y borrar de `BaseItems` las filas de esa ruta. Así se hizo con `Videoclips`.

**Cómo se revirtió la biblioteca anterior.** Quedan respaldos de la base de datos de Jellyfin y de los `.nfo` anteriores en el servidor. Los archivos de video no se tocaron: la carpeta nueva se creó con enlaces duros de los originales.

## Compilar

Se compila en GitHub Actions con el workflow `Build` (`.github/workflows/ci.yml`), que genera un IPA **sin firmar** como artefacto `Swiftfin tvOS-unsigned`.

- El workflow se dispara con un *push* a `main` o con un *pull request* hacia `main`. Un *push* a otra rama no lo ejecuta. Se abrió un PR **dentro del propio fork** (no hacia el repositorio original) para poder lanzarlo; cada *push* a la rama vuelve a compilar.
- En un fork nuevo hay que habilitar Actions a mano en la pestaña *Actions* de GitHub.
- Se compilan los dos esquemas (iOS y tvOS) en un runner `macos-26`. Solo el de tvOS interesa para el Apple TV.
- **Cola de runners.** GitHub tuvo poca capacidad de macOS arm64 en estos días, y cancelaba el job tras ~15 minutos sin conseguir runner (`The job was not acquired by Runner of type hosted`). Solución: relanzar solo el job de tvOS (`gh run rerun --job <id>`) hasta que consiga runner. Un script que vigila el run y relanza solo funcionó bien.
- Una compilación tarda unos **25 minutos** una vez con runner.
- **Caché de `DerivedData`** (`04ee460c`): se añadió para acelerar compilaciones posteriores, pero **casi no ayudó** (24,1 minutos frente a 26,9). Cada *checkout* cambia las fechas de los archivos, así que el código de Swiftfin se recompila entero. Se puede quitar sin pérdida; ocupa ~580 MB por esquema.
- Descargar el IPA: `gh run download <run> --repo ebravofm/Swiftfin -n "Swiftfin tvOS-unsigned"`.

Compilar en local exigiría Xcode 26. Según la tabla de Apple, Xcode 26.0–26.3 piden macOS Sequoia 15.6 o superior, y una fuente de terceros indica que 26.4 en adelante pide macOS 26.2; no se comprobó si el proyecto compila con Xcode 26.3.

## Instalar en el Apple TV

El Apple TV (`192.168.100.10`) tiene jailbreak rootful con palera1n y AppSync Unified. El IPA sin firmar del CI se instala por SSH en `/Applications/Swiftfin.app` y se firma ad-hoc con `ldid`. El *bundle id* es el original, `org.jellyfin.swiftfin`, y la firma no caduca. La guía completa, con el acceso SSH y qué hacer si se pierde el jailbreak, está en `/Users/laptop/Documents/Proyectos/tvos-jailbreak/CLAUDE.md`.

1. Bajar el IPA de la última build exitosa de la rama, y comprobar que el `headSha` sea el último commit:
   ```bash
   gh run list -b <rama> -w "Build 🔨" -L 3 --json databaseId,conclusion,headSha
   gh run download <databaseId> -n "Swiftfin tvOS-unsigned" -D <carpeta-vacía>
   ```
2. Descomprimir en el Mac (el Apple TV no tiene `unzip`) y empaquetar el `.app` con `COPYFILE_DISABLE=1 tar -C <carpeta>/Payload -cf swiftfin.tar Swiftfin.app`.
3. Pasar el `.tar` y los entitlements a `/tmp` del Apple TV: `scp swiftfin.tar swiftfin.entitlements appletv:/tmp/`. El alias `appletv` de `~/.ssh/config` entra como `root` con la llave `~/.ssh/appletv`, sin contraseña.
4. En el Apple TV: `killall Swiftfin`, descomprimir el `.tar`, reemplazar `/Applications/Swiftfin.app`, `chown -R root:wheel` y `chmod -R 755`.
5. Firmar los frameworks (`ldid -S` a cada `Frameworks/*.framework/<nombre>`; hoy solo `Libmpv`) y el ejecutable con `ldid -S/tmp/swiftfin.entitlements /Applications/Swiftfin.app/Swiftfin`.
6. `uicache -a` y `launchctl reboot userspace` (no quita el jailbreak).

Los entitlements tienen que incluir `application-identifier` y `keychain-access-groups` con `org.jellyfin.swiftfin`, además de `platform-application`, `com.apple.private.skip-library-validation` y `get-task-allow`. **Sin `com.apple.private.security.no-container`.** Sin los del Keychain, el token de sesión no se guarda, la app manda las peticiones sin token y el servidor responde 401 (`"Token is required"` en el log de Jellyfin). Comprobar después de firmar con `ldid -e /Applications/Swiftfin.app/Swiftfin`.
## Herramientas para depurar en el Apple TV

Se usaron, solo en local y sin versionar (`.venv` está excluido de git):

- **`pymobiledevice3`**: tras emparejar el Apple TV (`remote pair`, con un código que aparece en pantalla) y abrir un túnel con `sudo ... remote start-tunnel -t wifi -p tcp --udid <udid>`, permite sacar capturas (`developer dvt screenshot --rsd <dirección> <puerto>`), abrir la app (`developer dvt launch`) y listar apps. Con `-p tcp` funcionó; con QUIC dio error. La dirección y el puerto del túnel **cambian cada vez** que se abre.
- **`pyatv`**: emparejado por Companion, permite mandar botones. Se descartó para navegar: era poco fiable (el foco caía en otro lado). Convino que la persona navegue y solo se saquen las capturas.
- **`tcpdump`** en el contenedor del servidor Jellyfin, para ver qué pide la app y qué responde el servidor. Fue clave para encontrar la causa del `No Results`. Si la app usa la IP directa del servidor, el tráfico entra por la interfaz de red y no por la local.

## Pendiente y límites

- **No verificado:** el arreglo del `No Results` tras un rato en segundo plano; la portada de la playlist; *Play All* y *Shuffle* en conciertos; el comportamiento de la barra superior con 7 pestañas.
- La barra *Play All / Shuffle* se coloca en el borde superior de la lista y puede chocar con el título o el foco en algunas pantallas.
- *Play All* ignora los filtros activos: reproduce todo lo que hay bajo la biblioteca o carpeta.
- Dentro de una playlist, el botón de ordenar se ignora.
- La lista de playlists hace una petición extra por playlist para obtener la portada.
- Los textos nuevos (*Play All*, *Shuffle*, *Concerts*, *Video Clips*, *Playlists*) están escritos en inglés en el código, sin pasar por el sistema de traducciones.
- La biblioteca `Videoclips` solo se ve bien con esta versión: con el Swiftfin de serie aparece plana y sin imágenes.
- Pendiente de evaluar: llevar estos cambios al repositorio original como propuestas separadas. Hoy van todos en una sola rama.
