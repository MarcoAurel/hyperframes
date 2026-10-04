# Desplegar la API de render en EasyPanel

Guía para desplegar el servidor de render de HyperFrames (`@hyperframes/producer`)
como servicio **App** de EasyPanel, construido desde GitHub con
[`Dockerfile.easypanel`](../../Dockerfile.easypanel), con recursos limitados y
accesible solo por la red interna.

**Objetivo:** que el render sea lento antes que competir con otros procesos del servidor.

## Cómo funciona

```
Tu agente ──POST /render──▶  hyperframes-render (este servicio)
   │                          ├─ lee   /projects/<carpeta>   (composición + assets)
   │                          ├─ cola FIFO: 1 render a la vez
   │                          └─ escribe /renders/<job>.mp4
   └──GET /outputs/<token>──◀─ devuelve el MP4
```

- API: `POST /render`, `POST /render/stream` (progreso SSE), `GET /render/queue`,
  `POST /lint`, `GET /outputs/:token`, `GET /health`.
- **La API no tiene autenticación.** Por eso este servicio **no debe tener dominio público**.

## 1. Crear el servicio

En EasyPanel → tu proyecto → **New Service** → **App** → nombre, por ejemplo `hyperframes-render`.

**Source → GitHub**

| Campo      | Valor                                                                |
| ---------- | -------------------------------------------------------------------- |
| Repository | `MarcoAurel/hyperframes`                                             |
| Branch     | `ccr-f2372c34-29e03b` (o `main` cuando el Dockerfile esté fusionado) |
| Build Path | `/`                                                                  |

El **Build Path es también el contexto de Docker**, y debe ser la raíz del repositorio:
el Dockerfile copia varios paquetes del monorepo. Si el repositorio es privado,
configura antes el token de GitHub en el servidor.

**Build → Dockerfile**

| Campo           | Valor                  |
| --------------- | ---------------------- |
| Builder         | Dockerfile             |
| Dockerfile path | `Dockerfile.easypanel` |

EasyPanel construye con Buildx, por lo que `Dockerfile.easypanel.dockerignore`
se aplica automáticamente.

## 2. Variables de entorno

El Dockerfile ya trae valores por defecto. Solo agrega las que quieras cambiar (pestaña **Environment**):

```env
PRODUCER_MAX_WORKERS=2
PRODUCER_MAX_CONCURRENT_RENDERS=1
PRODUCER_LOW_MEMORY_MODE=true
```

| Variable                          | Qué hace                                                                                                                                                             |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PRODUCER_MAX_WORKERS`            | Tope de Chrome en paralelo por render. El motor calcula los workers con `os.cpus()`, que **ignora** el límite de CPU del contenedor; por eso se fija explícitamente. |
| `PRODUCER_MAX_CONCURRENT_RENDERS` | Renders simultáneos. Con `1`, el resto espera en cola.                                                                                                               |
| `PRODUCER_LOW_MEMORY_MODE`        | Perfil de bajo consumo (1 worker). Con 8 GB o menos se activa solo; aquí se fuerza.                                                                                  |

## 3. Recursos (pestaña **Resources**)

| Campo              | Valor recomendado |
| ------------------ | ----------------- |
| CPU limit          | `2`               |
| Memory limit       | `4096` MB         |
| CPU reservation    | `0.5`             |
| Memory reservation | `1024` MB         |

Un valor `0` significa "sin límite": no lo uses en los límites.

Además, el proceso corre con prioridad baja (`nice 10`), que se hereda a Chrome y FFmpeg.
Aun con límite de CPU, esto hace que el render ceda ante otros servicios cuando el servidor está ocupado.

> El **build** de la imagen (bun install, esbuild, descarga de Chrome) es la parte más pesada
> y corre en el servidor. Hazlo en un momento tranquilo. Si falla por memoria, súbela
> temporalmente solo para ese despliegue.

## 4. Mounts (pestaña **Storage**)

El Dockerfile crea `/projects` y `/renders`, pero **no puede montarlos**: se configuran aquí.

Tu agente necesita escribir las composiciones y assets donde el contenedor de render pueda leerlos.
La forma más directa de compartir carpetas entre dos servicios es un **Bind** a una
carpeta del servidor (créala antes en el host), montada en ambos:

| Tipo | Ruta del servidor           | Ruta en el contenedor | Para qué                                                           |
| ---- | --------------------------- | --------------------- | ------------------------------------------------------------------ |
| Bind | `/srv/hyperframes/projects` | `/projects`           | Carpetas de composición + assets (imágenes, video, audio, fuentes) |
| Bind | `/srv/hyperframes/renders`  | `/renders`            | MP4 de salida                                                      |

Monta **las mismas dos rutas** en el servicio de tu agente para que pueda dejar proyectos
en `/projects` y leer o borrar salidas de `/renders`. Los cambios de Storage requieren **Deploy**.

El contenedor corre como `root`, así que puede escribir en los mounts sin ajustar permisos.

Estructura esperada de cada proyecto:

```
/projects/mi-video/
├── index.html        ← composición
├── gsap.min.js       ← librerías LOCALES (ver nota)
├── logo.png
└── musica.mp3
```

> **Usa librerías locales, no CDN.** Un render con `<script src="https://cdnjs…/gsap.min.js">`
> falla si el servidor no tiene salida a Internet, y rompe la regla del proyecto de no hacer
> peticiones de red al renderizar. Copia `gsap.min.js` dentro del proyecto. Si dejas el atributo
> `integrity`, su hash debe coincidir exactamente con la versión que copies.

## 5. Red: solo interna

Los servicios App nuevos pueden traer un **dominio automático**. Hay que eliminarlo.

- **Domains:** borra cualquier dominio del servicio (incluido el automático). No añadas ninguno.
- **Advanced → Ports:** no publiques el 9847 ni el 9848.
- **Security (Basic Auth):** solo protege dominios. No hace falta si no hay dominio.

Los demás servicios del **mismo proyecto** lo alcanzan por el nombre interno. Siguiendo el patrón
de los ejemplos de la documentación de EasyPanel (`postgres://…@project_database:5432`),
la URL es:

```
http://<proyecto>_<servicio>:9847
```

Por ejemplo `http://miproyecto_hyperframes-render:9847`. Compruébalo desde la **Shell** del
servicio de tu agente: `curl http://<proyecto>_<servicio>:9847/health`.

## 6. Ajustes de despliegue (**Advanced → Deploy**)

| Ajuste           | Valor                                                                                      |
| ---------------- | ------------------------------------------------------------------------------------------ |
| Replicas         | `1` (más réplicas multiplican el consumo y comparten `/renders`)                           |
| Tini como init   | **Desactivado** (la imagen ya incluye `tini`)                                              |
| Command override | **Vacío** (el Dockerfile ya define el arranque)                                            |
| Auto Deploy      | **Desactivado** recomendado: cada push reconstruiría la imagen y gastaría CPU del servidor |

La imagen incluye un `HEALTHCHECK` propio contra el puerto 9848 (un hilo aparte que sigue
respondiendo aunque un render sature el proceso principal).

Pulsa **Deploy** y revisa los **Logs**. Deberías ver:

```
[INFO] Listening on http://localhost:9847
[INFO] [healthWorker] /health listening on worker thread, port 9848
```

## 7. Llamar a la API desde tu agente

Script de ejemplo: [`render.sh`](./render.sh) (requiere `curl` y `jq`).

```bash
export HF_RENDER_URL=http://miproyecto_hyperframes-render:9847
./render.sh mi-video ./mi-video.mp4
```

Petición equivalente:

```bash
curl -X POST "$HF_RENDER_URL/render" -H 'content-type: application/json' -d '{
  "projectDir": "/projects/mi-video",
  "outputPath": "/renders/mi-video-0001.mp4",
  "fps": 30,
  "quality": "standard",
  "format": "mp4"
}'
```

Respuesta:

```json
{
  "success": true,
  "outputToken": "…",
  "outputUrl": "/outputs/…",
  "fileSize": 129208,
  "videoDurationSeconds": 2,
  "durationMs": 4158
}
```

Luego `GET $HF_RENDER_URL/outputs/<outputToken>` descarga el MP4.

Estado de la cola: `GET /render/queue` → `{"maxConcurrentRenders":1,"activeRenders":0,"queuedRenders":0}`.
Validar antes de gastar CPU: `POST /lint`.

### Reglas para el agente

1. **No enviar el campo `workers`.** La API lo acepta y salta el tope `PRODUCER_MAX_WORKERS`.
2. **Enviar un `outputPath` único por trabajo** (por ejemplo `/renders/<proyecto>-<id>.mp4`).
   Por defecto el archivo se llama como la carpeta del proyecto y un segundo render lo sobrescribe.
   Usa una extensión acorde al `format` pedido (`.mp4`, `.webm`, `.mov`).
3. **Descargar el MP4 enseguida.** El enlace dura 15 minutos y vive solo en memoria:
   si el contenedor se reinicia, se pierde.
4. **Esperar con paciencia.** `POST /render` se queda abierto hasta terminar, y con otros
   renders en curso la petición espera su turno. Usa `/render/stream` si quieres ver
   `queued` y el progreso.

## 8. Mantenimiento

**Los MP4 de `/renders` no se borran solos.** El servidor solo borra las carpetas temporales
de proyectos inline. Si no se limpia, el disco se llena.

- Recomendado: que el agente borre el archivo de `/renders` tras descargarlo (comparten el Bind).
- Alternativa manual, desde la **Shell** del servicio:

  ```bash
  find /renders -name '*.mp4' -mmin +60 -delete
  ```

## Solución de problemas

| Síntoma                                        | Causa probable                                                                                                                  |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `Project directory not found`                  | La ruta del `projectDir` es la del **contenedor** (`/projects/…`), no la del servidor; o falta el Bind en uno de los servicios. |
| `sub_timeline_script_failure … failed to load` | La composición carga un script desde CDN y no hay salida a Internet. Usa una copia local.                                       |
| `…runtime-error:subresource-integrity`         | El `integrity` del `<script>` no coincide con el archivo local.                                                                 |
| Contenedor reiniciándose por memoria           | El render supera el límite de RAM (mucho video, resolución alta o composiciones pesadas). Baja la resolución o sube el límite.  |
| El agente no alcanza la API                    | El nombre interno es `<proyecto>_<servicio>`; verifica con `curl …/health` desde su Shell.                                      |
| El build se queda sin memoria                  | Súbela solo durante el despliegue.                                                                                              |
