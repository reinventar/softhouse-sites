#!/usr/bin/env python3
"""Remove da página do cliente os shows cuja data já passou.

Uso: python3 scripts/limpar_agenda.py sites/<slug>/index.html [AAAA-MM-DD]
Sem a data, usa o dia de hoje no fuso de São Paulo.
Remove (1) banners do início  <div class="hs" data-data="...">
        (2) linhas da agenda   <div class="show" data-data="...">
Imprime um resumo em JSON: removidos, restantes e próximas datas.
"""
import re, sys, json, datetime
try:
    from zoneinfo import ZoneInfo
    hoje = datetime.datetime.now(ZoneInfo("America/Sao_Paulo")).date()
except Exception:
    hoje = (datetime.datetime.utcnow() - datetime.timedelta(hours=3)).date()
arq = sys.argv[1]
if len(sys.argv) > 2:
    hoje = datetime.date.fromisoformat(sys.argv[2])
s = open(arq, encoding="utf-8").read()
orig = s
removidos = []
# banners do início: bloco de 6 espaços até o fechamento no mesmo recuo
pat_hs = re.compile(r'      <div class="hs[^"]*" data-data="(\d{4}-\d{2}-\d{2})".*?\n      </div>\n', re.S)
# linhas da agenda: bloco de 8 espaços
pat_show = re.compile(r'        <div class="show" data-data="(\d{4}-\d{2}-\d{2})">.*?\n        </div>\n', re.S)
def tira(m, tipo):
    d = datetime.date.fromisoformat(m.group(1))
    if d < hoje:
        removidos.append(f"{tipo} {m.group(1)}")
        return ""
    return m.group(0)
s = pat_hs.sub(lambda m: tira(m, "banner"), s)
s = pat_show.sub(lambda m: tira(m, "agenda"), s)
restantes = sorted(set(re.findall(r'class="show" data-data="(\d{4}-\d{2}-\d{2})"', s)))
if s != orig:
    open(arq, "w", encoding="utf-8").write(s)
print(json.dumps({"hoje": str(hoje), "alterado": s != orig, "removidos": removidos,
                  "restantes": len(restantes), "proximas": restantes}, ensure_ascii=False))
