DECORACIONES DE AVATAR — CONFIGURACIÓN JSON + GIF

ARCHIVO PRINCIPAL
- manifest.json: catálogo de decoraciones disponibles.
- rose-orbit.json, starlight.json y violet-frame.json: configuración editable individual.
- rose-orbit.gif y starlight.gif: GIF animados originales creados para este proyecto.
- violet-frame.svg: marco vectorial original.

CAMPOS POR DECORACIÓN
- pos: "overlay", "top" o "bottom".
- x / y: desplazamiento en porcentaje relativo al diámetro del avatar.
- scale: multiplicador de tamaño (por ejemplo 1.3 = 130%).
- fps: FPS objetivo de los efectos CSS y metadato del marco. La cadencia de fotogramas ya codificada dentro de un GIF no se puede cambiar con CSS; para cambiarla hay que exportar otro GIF con otra duración de fotograma.
- file: nombre de archivo del recurso gráfico.

La aplicación incluye un editor visual en Perfil > Decoración del avatar. Permite seleccionar marcos, ajustar pos/x/y/scale/fps, subir un GIF propio, exportar la configuración activa como JSON e importar otro JSON.

Para editar manualmente, modifica el JSON y después importa ese archivo desde el editor de decoración. La app local abre sus recursos con rutas relativas, así que conserva la estructura de carpetas.
