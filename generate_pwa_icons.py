"""Genera los iconos PWA de RiderFlasshi a partir del logo oficial.

Usa:
  - logo o pngg.png (transparente)  -> icon-192x192, icon-512x512 (notificaciones/PWA) y favicon
  - logo o.jpg      (con fondo)     -> maskable-icon-512x512 (instalación) y apple-touch-icon (iOS)
"""
import os
from PIL import Image, ImageOps

BASE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(BASE, "public", "icons")
LOGO_DIR = r"C:\Users\PcXpress\Desktop\logo ridesocopo"
os.makedirs(OUT_DIR, exist_ok=True)

LOGO_TRANSPARENTE = os.path.join(LOGO_DIR, "logo o pngg.png")
LOGO_FONDO = os.path.join(LOGO_DIR, "logo o.jpg")

MASKABLE_SAFE_ZONE = 0.80  # el 80% central del lienzo es la "zona segura"


def fit(img: Image.Image, size: int) -> Image.Image:
    """Redimensiona la imagen a 'size' (cuadrada) sin deformar ni recortar contenido."""
    return img.convert("RGBA").resize((size, size), Image.LANCZOS)


def make_maskable(src: str, size: int = 512) -> Image.Image:
    """Crea un icono maskable: el logo se reduce al 80% y se centra sobre el fondo."""
    logo = Image.open(src).convert("RGBA")
    bg = Image.open(src).convert("RGB").resize((size, size), Image.LANCZOS)

    # Obtener el bounding box del contenido (para centrar el logo correctamente)
    alpha = logo.split()[3]
    bbox = alpha.getbbox()
    if bbox:
        logo = logo.crop(bbox)

    inner = int(size * MASKABLE_SAFE_ZONE)
    logo = logo.resize((inner, inner), Image.LANCZOS)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(bg, (0, 0))
    x = (size - inner) // 2
    y = (size - inner) // 2
    canvas.paste(logo, (x, y), logo)
    return canvas


# --- Iconos con transparencia (notificaciones push + PWA "any") ---
transparente = Image.open(LOGO_TRANSPARENTE).convert("RGBA")
for filename, sz in [("icon-192x192.png", 192), ("icon-512x512.png", 512)]:
    fit(transparente, sz).save(os.path.join(OUT_DIR, filename), "PNG")
    print(f"  ✓ {filename} ({sz}x{sz}) [transparente]")

# --- Icono maskable (instalación en Android) - logo con fondo ---
make_maskable(LOGO_FONDO, 512).save(os.path.join(OUT_DIR, "maskable-icon-512x512.png"), "PNG")
print("  ✓ maskable-icon-512x512.png (512x512) [con fondo]")

# --- apple-touch-icon (iOS NO soporta transparencia: fondo negro) ---
Image.open(LOGO_FONDO).convert("RGB").resize((180, 180), Image.LANCZOS).save(
    os.path.join(OUT_DIR, "apple-touch-icon.png"), "PNG"
)
print("  ✓ apple-touch-icon.png (180x180) [con fondo]")

# --- favicon.png (pestaña del navegador) - logo transparente ---
fit(transparente, 64).save(os.path.join(BASE, "public", "favicon.png"), "PNG")
print("  ✓ favicon.png (64x64) [transparente]")

print("\nIconos PWA generados correctamente en public/icons/")