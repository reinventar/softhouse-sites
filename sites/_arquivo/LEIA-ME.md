# Sites arquivados

Pastas aqui dentro **não são publicadas** (o workflow "Publicar sites" ignora pastas que começam com `_`).

| Cliente | Arquivado em | Motivo | Endereço que estava no ar |
|---|---|---|---|
| Toninho Saga (`toninho-saga`) | 18/11/2026 | Cliente pediu para retomar no ano que vem | toninhosaga.reinventar.dev |

## Como publicar de novo
1. `git mv sites/_arquivo/<slug> sites/<slug>` e envie para a `main`.
2. A automação "Publicar sites" recria o domínio e o DNS sozinha (o projeto `sh-<slug>` continua existindo na Cloudflare).
3. No vídeo de marketing, volte os caminhos de `marketing/videos/<slug>/config.json` para `sites/<slug>/`.
