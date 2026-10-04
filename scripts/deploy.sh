#!/usr/bin/env bash
# Publica um cliente: sites/<slug>/ -> Cloudflare Pages + subdomínio da softhouse (+ domínio próprio opcional).
# Uso: bash scripts/deploy.sh <slug>
set -euo pipefail

slug="$1"
dir="sites/$slug"
cfg="$dir/site.json"
api="https://api.cloudflare.com/client/v4"
auth=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")

[ -f "$dir/index.html" ] || { echo "::error::$dir/index.html não existe"; exit 1; }
[ -f "$cfg" ] || { echo "::error::$cfg não existe"; exit 1; }

sub=$(jq -r '.subdominio // empty' "$cfg")
own=$(jq -r '.dominio_proprio // empty' "$cfg")
project="sh-${slug}"
pages_host="${project}.pages.dev"

echo "== $slug -> projeto $project"

# 1. Projeto (cria se não existir)
if ! curl -fsS "${auth[@]}" "$api/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project" >/dev/null 2>&1; then
  curl -fsS "${auth[@]}" -X POST "$api/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects" \
    -d "{\"name\":\"$project\",\"production_branch\":\"main\"}" >/dev/null
  echo "projeto criado"
fi

# 2. Publicar os arquivos (site.json não vai para o ar)
out=$(mktemp -d)
rsync -a --exclude site.json "$dir/" "$out/"
npx --yes wrangler@3 pages deploy "$out" --project-name "$project" --branch main --commit-dirty=true

# 3. Ligar um domínio ao projeto (ignora se já estiver ligado)
attach_domain () {
  local host="$1"
  curl -sS "${auth[@]}" -X POST "$api/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project/domains" \
    -d "{\"name\":\"$host\"}" | jq -r 'if .success then "domínio ligado: \(.result.name)" else "domínio: \(.errors[0].message)" end'
}

# 4. Registro DNS (CNAME com proxy) numa zona, ignora se já existir
upsert_cname () {
  local zone="$1" name="$2"
  local existing
  existing=$(curl -fsS "${auth[@]}" "$api/zones/$zone/dns_records?type=CNAME&name=$name" | jq -r '.result[0].id // empty')
  if [ -z "$existing" ]; then
    curl -fsS "${auth[@]}" -X POST "$api/zones/$zone/dns_records" \
      -d "{\"type\":\"CNAME\",\"name\":\"$name\",\"content\":\"$pages_host\",\"proxied\":true}" >/dev/null
    echo "DNS criado: $name -> $pages_host"
  fi
}

urls=("https://$pages_host")

# Subdomínio da softhouse
if [ -n "$sub" ] && [ -n "${SOFTHOUSE_DOMAIN:-}" ]; then
  host="$sub.$SOFTHOUSE_DOMAIN"
  attach_domain "$host"
  upsert_cname "$CF_ZONE_ID" "$host"
  urls+=("https://$host")
fi

# Domínio próprio do cliente (zona criada na conta; o cliente aponta os DNS no Registro.br)
if [ -n "$own" ]; then
  zone=$(curl -fsS "${auth[@]}" "$api/zones?name=$own" | jq -r '.result[0].id // empty')
  if [ -z "$zone" ]; then
    zone=$(curl -fsS "${auth[@]}" -X POST "$api/zones" \
      -d "{\"name\":\"$own\",\"account\":{\"id\":\"$CLOUDFLARE_ACCOUNT_ID\"},\"type\":\"full\"}" | jq -r '.result.id')
  fi
  ns=$(curl -fsS "${auth[@]}" "$api/zones/$zone" | jq -r '.result.name_servers | join(" e ")')
  status=$(curl -fsS "${auth[@]}" "$api/zones/$zone" | jq -r '.result.status')
  attach_domain "$own"
  upsert_cname "$zone" "$own"
  urls+=("https://$own")
  {
    echo "### Domínio próprio: $own"
    echo "- Situação da zona: **$status**"
    [ "$status" != "active" ] && echo "- No Registro.br, troque os servidores DNS de $own para: **$ns**"
  } >> "$GITHUB_STEP_SUMMARY"
fi

{
  echo "### $slug publicado"
  for u in "${urls[@]}"; do echo "- $u"; done
} >> "$GITHUB_STEP_SUMMARY"
echo "OK: ${urls[*]}"
