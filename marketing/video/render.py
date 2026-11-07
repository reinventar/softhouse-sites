#!/usr/bin/env python3
"""Gera o vídeo de entrega do site (Reels 9:16) a partir de uma config JSON.

Uso:
  python3 marketing/video/render.py --config marketing/videos/<slug>/config.json \
      --saida marketing/videos/<slug>/entrega.mp4 \
      [--audio marketing/audio/lost_in_the_fire_instrumental.mp3 --inicio 7] \
      [--fontes fontes.css] [--fps 30] [--previa]

- Caminhos de imagem na config são relativos à pasta da config (ou à raiz do repo, se começarem com "sites/").
- Se a config tiver "site": "sites/<slug>/index.html", o print do celular é tirado sozinho, e cada parada
  pode usar "seletor" (ex.: "#resultados") em vez de "y".
- --fontes: CSS com @font-face locais (o container não acessa o Google Fonts). Ver SKILL do agente de marketing.
- --previa: em vez do vídeo, salva 1 quadro por cena em <saida>-previa/ para conferir rápido.
"""
import argparse, json, os, subprocess, sys
from playwright.sync_api import sync_playwright

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.abspath(os.path.join(AQUI, "..", ".."))
LARG_TELA = 604   # largura útil da tela do celular no modelo (640 - 2*18)

def caminho(base, v):
    if not v or v.startswith(("http://", "https://", "file://", "data:")): return v
    p = os.path.join(RAIZ, v) if v.startswith("sites/") else os.path.join(base, v)
    return "file://" + os.path.abspath(p)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True); ap.add_argument("--saida", required=True)
    ap.add_argument("--audio", default=os.path.join(RAIZ, "marketing/audio/lost_in_the_fire_instrumental.mp3"))
    ap.add_argument("--inicio", type=float, default=7.0, help="segundo da música onde o vídeo começa")
    ap.add_argument("--fontes", default=None); ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--previa", action="store_true")
    a = ap.parse_args()

    base = os.path.dirname(os.path.abspath(a.config))
    cfg = json.load(open(a.config))
    css = open(a.fontes).read() if a.fontes else ""
    os.makedirs(os.path.dirname(os.path.abspath(a.saida)), exist_ok=True)

    for k in ("foto_principal", "foto_passos", "print_site"):
        cfg[k] = caminho(base, cfg.get(k))
    for s in cfg.get("servicos", []): s["foto"] = caminho(base, s.get("foto"))
    if cfg.get("resultado"):
        for k in ("antes", "depois"): cfg["resultado"][k] = caminho(base, cfg["resultado"].get(k))

    with sync_playwright() as p:
        b = p.chromium.launch()

        # 1) print do site no celular + posição de cada parada
        if cfg.get("site"):
            esc = LARG_TELA / 390          # escala de exibição na tela do celular
            def abrir(dsf):
                ctx = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=dsf)
                pg = ctx.new_page()
                pg.route("https://fonts.googleapis.com/**", lambda r: r.fulfill(status=200, content_type="text/css", body=css))
                pg.route("https://fonts.gstatic.com/**", lambda r: r.abort())
                pg.goto(caminho(base, cfg["site"]), wait_until="load")
                pg.add_style_tag(content=".demo,.preview,.previa,.wa,[class*=preview]{display:none!important} *{animation:none!important;transition:none!important}")
                pg.evaluate("document.querySelectorAll('img[loading=lazy]').forEach(i=>i.loading='eager')")
                pg.evaluate("document.fonts.ready"); pg.wait_for_timeout(1500)
                return ctx, pg
            ctx, pg = abrir(1)
            altura = pg.evaluate("document.documentElement.scrollHeight"); ctx.close()
            dsf = min(esc, 15500 / altura)   # o Chromium não captura imagens com mais de ~16 mil px
            ctx, pg = abrir(dsf)
            altura = pg.evaluate("document.documentElement.scrollHeight")
            for pa in cfg.get("paradas", []):
                if "seletor" in pa:
                    y = pg.evaluate("s => { const e = document.querySelector(s); return e ? e.getBoundingClientRect().top + scrollY : 0 }", pa["seletor"])
                    pa["y"] = max(0, min(y - pa.get("margem", 10), altura - 780)) * esc
                pa.setdefault("y", 0)
            arq = os.path.splitext(a.saida)[0] + "-print-site.png"
            pg.screenshot(path=arq, full_page=True, clip={"x": 0, "y": 0, "width": 390, "height": altura})
            cfg["print_site"] = "file://" + os.path.abspath(arq)
            ctx.close()

        # 2) quadros
        pg = b.new_page(viewport={"width": 1080, "height": 1920})
        pg.add_init_script("window.CFG = " + json.dumps(cfg) + ";")
        pg.goto("file://" + os.path.join(AQUI, "modelo-entrega.html"), wait_until="load")
        pg.evaluate("css => { document.getElementById('fontes').textContent = css }", css)
        pg.evaluate("document.fonts.ready"); pg.wait_for_timeout(1200)
        dur = pg.evaluate("window.DURACAO")
        n = int(round(dur * a.fps))

        if a.previa:
            d = os.path.splitext(a.saida)[0] + "-previa"; os.makedirs(d, exist_ok=True)
            for i, t in enumerate([2.4, 5.0, 7.0, 10.0, 13.5, 16.5, 20.0, 23.5, 28.0]):
                if t >= dur: break
                pg.evaluate(f"window.seek({t})"); pg.screenshot(path=f"{d}/q{i:02d}-{t:.1f}s.jpg", type="jpeg", quality=80)
            print("prévia em", d, "· duração", round(dur, 1), "s"); b.close(); return

        temp = os.path.splitext(a.saida)[0] + "-mudo.mp4"
        enc = subprocess.Popen(["ffmpeg", "-y", "-v", "error", "-f", "image2pipe", "-framerate", str(a.fps), "-i", "-",
                                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-preset", "medium", temp], stdin=subprocess.PIPE)
        for i in range(n):
            pg.evaluate(f"window.seek({i / a.fps})")
            enc.stdin.write(pg.screenshot(type="jpeg", quality=92))
            if i % 90 == 0: print(f"quadro {i}/{n}", flush=True)
        enc.stdin.close(); enc.wait(); b.close()

    # 3) áudio: trecho da música, fade e volume padrão do Instagram (-14 LUFS)
    if a.audio and os.path.exists(a.audio):
        f = f"afade=t=in:d=0.25,afade=t=out:st={max(0, dur - 1.4):.2f}:d=1.4,loudnorm=I=-14:TP=-1.5:LRA=11"
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", temp, "-ss", str(a.inicio), "-t", f"{dur:.2f}", "-i", a.audio,
                        "-af", f, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                        "-movflags", "+faststart", "-shortest", a.saida], check=True)
        os.remove(temp)
    else:
        os.replace(temp, a.saida)
    print("pronto:", a.saida, f"({dur:.1f} s)")

if __name__ == "__main__":
    main()
