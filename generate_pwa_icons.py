"""Genera los iconos PWA para RideSocopó usando solo Pillow (sin Cairo)."""
import os
from PIL import Image, ImageDraw, ImageFont

BASE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(BASE, "public", "icons")
os.makedirs(OUT_DIR, exist_ok=True)


def make_icon(size: int):
    """Crea un icono hexágono morado con 'R' centrada."""
    # Fondo morado sólido (Android muestra blanco si hay transparencia)
    img = Image.new("RGBA", (size, size), (124, 58, 237, 255))
    draw = ImageDraw.Draw(img)

    # Centrado en el lienzo
    cx, cy = size / 2, size / 2
    radius = size * 0.48  # El hexágono ocupa el 96% del icono

    # Puntos del hexágono (puntiagudo hacia arriba)
    pts = []
    for i in range(6):
        angle_deg = 60 * i - 90
        import math
        angle = math.radians(angle_deg)
        x = cx + radius * math.cos(angle)
        y = cy + radius * math.sin(angle)
        pts.append((x, y))

    # Gradiente morado -> azul
    top_color = (124, 58, 237, 255)   # #7c3aed
    bottom_color = (2, 132, 199, 255)  # #0284c7

    # Dibujar hexágono con gradiente vertical (bandas finas)
    min_y = min(p[1] for p in pts)
    max_y = max(p[1] for p in pts)
    steps = max(40, size // 4)
    for i in range(steps):
        y0 = min_y + (max_y - min_y) * i / steps
        y1 = min_y + (max_y - min_y) * (i + 1) / steps
        t = i / steps
        color = (
            int(top_color[0] + (bottom_color[0] - top_color[0]) * t),
            int(top_color[1] + (bottom_color[1] - top_color[1]) * t),
            int(top_color[2] + (bottom_color[2] - top_color[2]) * t),
            255,
        )
        # Máscara del polígono: dibujar línea horizontal solo dentro del hexágono
        mask = Image.new("L", (size, size), 0)
        mdraw = ImageDraw.Draw(mask)
        mdraw.polygon(pts, fill=255)
        # Tomar la franja
        band = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        bdraw = ImageDraw.Draw(band)
        bdraw.rectangle([0, int(y0), size, int(y1)], fill=color)
        img = Image.composite(band, img, mask)

    # Hexágono interior (borde blanco)
    inner_radius = radius * 0.72
    inner_pts = []
    for i in range(6):
        angle_deg = 60 * i - 90
        import math
        angle = math.radians(angle_deg)
        x = cx + inner_radius * math.cos(angle)
        y = cy + inner_radius * math.sin(angle)
        inner_pts.append((x, y))
    draw = ImageDraw.Draw(img)
    draw.polygon(inner_pts, outline=(255, 255, 255, 255), width=max(2, size // 40))

    # Letra "R" blanca centrada
    font_size = int(size * 0.5)
    try:
        font = ImageFont.truetype("arial.ttf", font_size)
    except Exception:
        font = ImageFont.load_default()

    # Obtener tamaño del texto
    bbox = draw.textbbox((0, 0), "R", font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    text_x = cx - text_w / 2 - bbox[0]
    text_y = cy - text_h / 2 - bbox[1]

    draw.text((text_x, text_y), "R", fill=(255, 255, 255, 255), font=font)

    return img


# Generar todos los tamaños
sizes = {
    "icon-192x192.png": 192,
    "icon-512x512.png": 512,
    "apple-touch-icon.png": 180,
    "maskable-icon-512x512.png": 512,
}

# Para maskable, el icono debe tener "safe zone" (el 80% central se usa)
# Creamos el mismo hexágono pero con más margen (fondo del color dominante)
maskable = Image.new("RGBA", (512, 512), (124, 58, 237, 255))  # fondo morado sólido
maskable_icon = make_icon(512)
# Escalar el icono al 80% y centrarlo sobre el fondo
maskable_icon = maskable_icon.resize((int(512 * 0.8), int(512 * 0.8)), Image.LANCZOS)
maskable.paste(maskable_icon, (int(512 * 0.1), int(512 * 0.1)), maskable_icon)
maskable.save(os.path.join(OUT_DIR, "maskable-icon-512x512.png"))

for filename, sz in sizes.items():
    img = make_icon(sz)
    img.save(os.path.join(OUT_DIR, filename), "PNG")
    print(f"  ✓ {filename} ({sz}x{sz})")

print("\nIconos PWA generados correctamente en public/icons/")