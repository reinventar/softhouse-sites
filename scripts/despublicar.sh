#!/usr/bin/env bash
# Tira um cliente do ar SEM apagar o projeto nem o código:
#  1) publica uma página "indisponível" (noindex) no projeto sh-<slug> (o endereço *.pages.dev deixa de mostrar o site)
#  2) desliga do projeto todos os domínios (subdomínio da softhouse e domínio próprio)
#  3) apaga os registros DNS que apontam para sh-<slug>.pages.dev
# Para voltar: tirar o site de sites/_arquivo/ e publicar de novo (workflow "Publicar sites").
# Uso: bash scripts/despublicar.sh <slug>
set -uo pipefail
slug="$1"; project="sh-${slug}"; pages_host="${project}.pages.dev"
api="https://api.cloudflare.com/client/v4"; H="Authorization: Bearer $CLOUDFLARE_API_TOKEN"
fail () { echo "::error title=$slug::$1"; exit 1; }
ok () { echo "$1" | jq -e '.success == true' >/dev/null 2>&1; }

r=$(curl -sS -H "$H" "$api/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project")
ok "$r" || fail "Projeto $project não encontrado"

# 1) página de indisponível
out=$(mktemp -d)
cat > "$out/index.html" <<'HTML'
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>Site indisponível</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0B0A0C;color:#FAF8F9;font-family:system-ui,sans-serif;text-align:center;padding:24px}p{color:#A39AA0}</style>
</head><body><div><h1>Site indisponível no momento</h1><p>Este endereço não está ativo.</p></div></body></html>
HTML
cp "$out/index.html" "$out/404.html"
printf 'User-agent: *\nDisallow: /\n' > "$out/robots.txt"
printf '/*\n  X-Robots-Tag: noindex, nofollow\n' > "$out/_headers"
npx --yes wrangler@3 pages deploy "$out" --project-name "$project" --branch main --commit-dirty=true >/tmp/w.log 2>&1 \
  && echo "::notice title=$slug::Página de indisponível publicada em https://$pages_host" \
  || { cat /tmp/w.log; fail "wrangler falhou"; }

# 2) desligar domínios do projeto
r=$(curl -sS -H "$H" "$api/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project/domains")
hosts=$(echo "$r" | jq -r '.result[]?.name')
for h in $hosts; do
  d=$(curl -sS -X DELETE -H "$H" "$api/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project/domains/$h")
  ok "$d" && echo "::notice title=$slug::Domínio desligado: $h" || echo "::warning title=$slug::Não desliguei $h: $(echo "$d" | jq -c '.errors')"
done

# 3) apagar DNS que apontam para o projeto (zona da softhouse e zonas dos domínios próprios)
zones=""
[ -n "${CF_ZONE_ID:-}" ] && zones="$CF_ZONE_ID"
for h in $hosts; do
  base=$(echo "$h" | sed 's/^www\.//')
  z=$(curl -sS -H "$H" "$api/zones?name=$base" | jq -r '.result[0].id // empty'); [ -n "$z" ] && zones="$zones $z"
done
for z in $(echo $zones | tr ' ' '\n' | sort -u); do
  curl -sS -H "$H" "$api/zones/$z/dns_records?type=CNAME&per_page=500" \
    | jq -r --arg t "$pages_host" '.result[] | select(.content == $t) | "\(.id) \(.name)"' \
    | while read -r id name; do
        d=$(curl -sS -X DELETE -H "$H" "$api/zones/$z/dns_records/$id")
        ok "$d" && echo "::notice title=$slug::DNS apagado: $name" || echo "::warning title=$slug::DNS não apagado: $name"
      done
done
echo "::notice title=$slug::Despublicado. Domínios desligados: ${hosts:-nenhum}"
