#!/usr/bin/env bash
# Publica um cliente: sites/<slug>/ -> Cloudflare Pages + subdomínio da softhouse (+ domínio próprio opcional).
# Uso: bash scripts/deploy.sh <slug>
# Erros viram anotações (::error::) para poderem ser lidos pela API do GitHub.
set -uo pipefail

slug="$1"
dir="sites/$slug"
cfg="$dir/site.json"
api="https://api.cloudflare.com/client/v4"

fail () { echo "::error title=$slug::$1"; exit 1; }

[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || fail "Secret CLOUDFLARE_API_TOKEN vazio"
[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || fail "Secret CLOUDFLARE_ACCOUNT_ID vazio"
[ -f "$dir/index.html" ] || fail "$dir/index.html não existe"
[ -f "$cfg" ] || fail "$cfg não existe"

# Chamada à API da Cloudflare: cf MÉTODO CAMINHO [JSON]; devolve o JSON; falha com anotação se success=false
cf () {
  local method="$1" path="$2" body="${3:-}" out
  if [ -n "$body" ]; then
    out=$(curl -sS -X "$method" "$api$path" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" --data "$body")
  else
    out=$(curl -sS -X "$method" "$api$path" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
  fi
  echo "$out"
}
ok () { echo "$1" | jq -e '.success == true' >/dev/null 2>&1; }
errs () { echo "$1" | jq -c '[.errors[]? | {code, message}]' 2>/dev/null || echo "$1" | head -c 300; }

# 0. Token válido?
r=$(cf GET "/user/tokens/verify")
ok "$r" || fail "Token da Cloudflare inválido: $(errs "$r")"

sub=$(jq -r '.subdominio // empty' "$cfg")
own=$(jq -r '.dominio_proprio // empty' "$cfg")
project="sh-${slug}"
pages_host="${project}.pages.dev"
echo "== $slug -> projeto $project"

# 1. Projeto (cria se não existir)
r=$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project")
if ! ok "$r"; then
  r=$(cf POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects" "{\"name\":\"$project\",\"production_branch\":\"main\"}")
  ok "$r" || fail "Não consegui criar o projeto $project: $(errs "$r")"
  echo "projeto criado"
fi

# 2. Publicar os arquivos (site.json não vai para o ar)
out=$(mktemp -d)
rsync -a --exclude site.json "$dir/" "$out/"
log=$(mktemp)
if ! npx --yes wrangler@3 pages deploy "$out" --project-name "$project" --branch main --commit-dirty=true >"$log" 2>&1; then
  cat "$log"
  fail "wrangler falhou: $(tail -n 8 "$log" | tr '\n' ' ' | tr -d '\r' | head -c 600)"
fi
cat "$log"

urls=("https://$pages_host")

attach_domain () {
  local host="$1" r
  r=$(cf POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project/domains" "{\"name\":\"$host\"}")
  if ok "$r"; then echo "domínio ligado: $host"
  elif echo "$r" | grep -qi "already"; then echo "domínio já ligado: $host"
  else echo "::warning title=$slug::Domínio $host: $(errs "$r")"; fi
}

upsert_cname () {
  local zone="$1" name="$2" r id
  r=$(cf GET "/zones/$zone/dns_records?type=CNAME&name=$name")
  id=$(echo "$r" | jq -r '.result[0].id // empty')
  if [ -z "$id" ]; then
    r=$(cf POST "/zones/$zone/dns_records" "{\"type\":\"CNAME\",\"name\":\"$name\",\"content\":\"$pages_host\",\"proxied\":true}")
    ok "$r" && echo "DNS criado: $name -> $pages_host" || echo "::warning title=$slug::DNS $name: $(errs "$r")"
  fi
}

# Subdomínio da softhouse
if [ -n "$sub" ] && [ -n "${SOFTHOUSE_DOMAIN:-}" ]; then
  host="$sub.$SOFTHOUSE_DOMAIN"
  attach_domain "$host"
  if [ -n "${CF_ZONE_ID:-}" ]; then
    r=$(cf GET "/zones/$CF_ZONE_ID")
    if ok "$r"; then echo "::notice title=zona::$(echo "$r" | jq -r '"\(.result.name) · status \(.result.status)"')"; else echo "::warning title=zona::CF_ZONE_ID não encontrado: $(errs "$r")"; fi
    upsert_cname "$CF_ZONE_ID" "$host"
  else echo "::warning::CF_ZONE_ID vazio"; fi
  urls+=("https://$host")
fi

# Domínio próprio do cliente
if [ -n "$own" ]; then
  r=$(cf GET "/zones?name=$own")
  zone=$(echo "$r" | jq -r '.result[0].id // empty')
  if [ -z "$zone" ]; then
    r=$(cf POST "/zones" "{\"name\":\"$own\",\"account\":{\"id\":\"$CLOUDFLARE_ACCOUNT_ID\"},\"type\":\"full\"}")
    ok "$r" || fail "Não consegui criar a zona $own: $(errs "$r")"
    zone=$(echo "$r" | jq -r '.result.id')
  fi
  r=$(cf GET "/zones/$zone")
  ns=$(echo "$r" | jq -r '.result.name_servers | join(" e ")')
  status=$(echo "$r" | jq -r '.result.status')
  attach_domain "$own"
  upsert_cname "$zone" "$own"
  urls+=("https://$own")
  [ "$status" != "active" ] && echo "::notice title=$slug::No Registro.br, troque os DNS de $own para: $ns"
fi

{
  echo "### $slug publicado"
  for u in "${urls[@]}"; do echo "- $u"; done
} >> "$GITHUB_STEP_SUMMARY"
echo "::notice title=$slug::Publicado: ${urls[*]}"
