#!/usr/bin/env python3
"""Baixa (npm) as fontes do cliente e gera um CSS com @font-face locais para o render.py.

O container do Claude não acessa o Google Fonts, mas acessa o npm. Uso:
  python3 marketing/video/fontes.py "Barlow Condensed" "Barlow" --saida /tmp/fontes.css
Famílias aceitas: qualquer uma do Google Fonts publicada como @fontsource/<nome-com-hifens>,
mais "Geist" e "Geist Mono" (pacote geist). Para Archivo com largura variável use "Archivo".
"""
import argparse, glob, os, re, subprocess, sys, tempfile

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("familias", nargs="+"); ap.add_argument("--saida", required=True)
    ap.add_argument("--pasta", default=os.path.join(tempfile.gettempdir(), "reinventar-fontes"))
    a = ap.parse_args()
    os.makedirs(a.pasta, exist_ok=True)
    if not os.path.exists(os.path.join(a.pasta, "package.json")):
        subprocess.run(["npm", "init", "-y"], cwd=a.pasta, capture_output=True)
    pk = []
    for f in a.familias:
        if f.startswith("Geist"): pk.append("geist@1")
        elif f == "Archivo": pk.append("@fontsource-variable/archivo")
        else: pk.append("@fontsource/" + f.lower().replace(" ", "-"))
    r = subprocess.run(["npm", "i", "-s"] + sorted(set(pk)), cwd=a.pasta, capture_output=True, text=True)
    if r.returncode: print(r.stderr[-800:]); sys.exit(1)
    nm = os.path.join(a.pasta, "node_modules"); out = []
    for f in a.familias:
        if f in ("Geist", "Geist Mono"):
            sub, pre = ("geist-mono", "GeistMono") if f.endswith("Mono") else ("geist-sans", "Geist")
            for w, n in [(400, "Regular"), (500, "Medium"), (600, "SemiBold"), (700, "Bold"), (800, "ExtraBold"), (900, "Black")]:
                out.append(f"@font-face{{font-family:'{f}';src:url('file://{nm}/geist/dist/fonts/{sub}/{pre}-{n}.woff2');font-weight:{w}}}")
        elif f == "Archivo":
            arq = f"{nm}/@fontsource-variable/archivo/files/archivo-latin-wdth-normal.woff2"
            out.append(f"@font-face{{font-family:'Archivo';src:url('file://{arq}');font-weight:100 900;font-stretch:62% 125%}}")
        else:
            d = f"{nm}/@fontsource/{f.lower().replace(' ', '-')}/files"
            for arq in glob.glob(d + "/*-latin-*-*.woff2"):
                m = re.search(r"-latin-(\d+)-(normal|italic)\.woff2$", arq)
                if m: out.append(f"@font-face{{font-family:'{f}';src:url('file://{arq}');font-weight:{m.group(1)};font-style:{m.group(2)}}}")
    open(a.saida, "w").write("\n".join(out)); print(len(out), "estilos de fonte em", a.saida)

if __name__ == "__main__":
    main()
