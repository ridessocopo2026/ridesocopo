"""Genera el icono de notificaciones push de RiderFlasshi.

Sale de logo-morado.png (la "R" transparente oficial) y produce un PNG
192x192 con fondo transparente y la "R" centrada con margen, optimizado
para Web Push (las notificaciones se ven mejor con fondo transparente
que con el cuadro opaco de los iconos PWA).
"""
import os
from PIL import Image

BASE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(BASE, "public", "icons", "logo-morado.png")
OUT = os.path.join(BASE, "public", "icons", "notification-icon-192.png")

SIZE = 192
PADDING_RATIO = 0.14  # margen transparente alrededor de la "R"


def main() -> None:
    logo = Image.open(SRC).convert("RGBA")

    # Recortar al contenido real (la imagen fuente tiene mucho margen)
    bbox = logo.split()[3].getbbox()
    if bbox:
        logo = logo.crop(bbox)

    # Redimensionar la "R" para que ocupe (1 - 2*padding) del lienzo
    w, h = logo.size
    target = int(SIZE * (1 - 2 * PADDING_RATIO))
    scale = target / max(w, h)
    nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
    logo = logo.resize((nw, nh), Image.LANCZOS)

    # Centrar sobre lienzo transparente
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    canvas.paste(logo, ((SIZE - nw) // 2, (SIZE - nh) // 2), logo)
    canvas.save(OUT, "PNG")
    print(f"OK -> {OUT} ({SIZE}x{SIZE}), logo renderizado {nw}x{nh}")


if __name__ == "__main__":
    main()
