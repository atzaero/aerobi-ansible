# Role: `gotenberg`

Sobe o **Gotenberg** (API HTTP **stateless** de conversão HTML→PDF via
Chromium) via Docker na rede `warpgate`. Serviço **interno** — nenhuma porta
publicada no host, sem vhost/DNS/TLS e sem secret: as `aerobi-api` de staging
e prod consomem via `http://gotenberg:3000`. Issue de infra:
`atzaero/aerobi-ansible#168`; epic de export PDF: `atzaero/aerobi-api#644`.

## Decisão de arquitetura: instância única (staging + prod)

Uma única instância serve os dois ambientes — mesmo padrão de
`postgres`/`valkey`/`minio`/`evolution_go`:

- O Gotenberg **não persiste nada**: recebe HTML, devolve bytes, esquece.
  Não há estado pra vazar entre ambientes.
- A superfície que varia por ambiente são os **templates HTML**, que vivem na
  `aerobi-api` — essa sim separada por ambiente.
- Upgrade futuro: subir instância temporária com a versão nova, apontar o
  staging via `GOTENBERG_URL`, validar os PDFs e promover. A separação é
  manobra pontual de upgrade, não custo permanente de RAM.

## Por que limite de memória (primeiro do repo)

`memory: 1g` é o **primeiro** teto de RAM de container do repo, de propósito:
o Chromium sob carga (páginas grandes, imagens pesadas, conversões
concorrentes) é o único serviço com risco real de estourar a memória da VPS e
levar vizinhos junto (Postgres, Headscale). Os demais serviços têm perfil de
memória previsível e não precisam de teto. Se o Gotenberg estourar o limite,
o OOM kill fica contido no container — o `docker_events_alerter` (issue #165)
reporta no GlitchTip e o `restart_policy: unless-stopped` ressuscita.

Complementos de proteção:

- `shm_size: 512M` — o `/dev/shm` default de 64 MB do Docker derruba o
  Chromium ("session deleted because of page crash").
- `--api-timeout=30s` — aborta conversões penduradas (é o default do
  Gotenberg; explícito pra ficar declarado/diffável).
- `--chromium-max-queue-size=10` — sob sobrecarga devolve 503 rápido em vez
  de enfileirar sem limite até estourar memória (default 0 = ilimitado).
- `--chromium-deny-private-ips=true` — bloqueia o Chromium de buscar recursos
  em IPs privados. Sem isso, o Gotenberg (API sem autenticação que renderiza
  HTML arbitrário) vira proxy de SSRF contra os serviços internos da
  `warpgate` — inclusive o Headscale, crown jewel do threat model
  (`docs/SECURITY.md`). **Contrato com a `aerobi-api`**: os templates HTML não
  podem referenciar assets em hosts internos (ex.: `http://aerobi-api:3333/…`)
  — embutir como base64/inline ou usar URL pública.

## Pré-requisitos

| Role | Por quê |
|---|---|
| `docker` + `docker_network` | Container + rede `warpgate` |

Nenhum secret no vault — a API do Gotenberg não tem autenticação e só é
alcançável de dentro da rede `warpgate` (nenhuma porta publicada no host).

## Variáveis (`defaults/main.yml`)

| Variável | Default | Descrição |
|---|---|---|
| `gotenberg_image` | `gotenberg/gotenberg` | Imagem (Docker Hub). |
| `gotenberg_version` | `8.34.0` | Tag pinada — bumpar revisando [releases](https://github.com/gotenberg/gotenberg/releases) e validando com `docker manifest inspect`. |
| `gotenberg_container_name` | `gotenberg` | Nome/alias DNS na `warpgate`. |
| `gotenberg_port` | `3000` | Porta **interna** do container (`--api-port` default) — não publicada no host; não colide com a 3000 do host (aerobi-web). |
| `gotenberg_shm_size` | `512M` | `/dev/shm` do container (Chromium). |
| `gotenberg_memory_limit` | `1g` | Teto de RAM do container (ver acima). |
| `gotenberg_api_timeout` | `30s` | `--api-timeout` (time limit por request). |
| `gotenberg_chromium_max_queue_size` | `10` | `--chromium-max-queue-size` (0 = fila ilimitada). |
| `gotenberg_chromium_deny_private_ips` | `"true"` | `--chromium-deny-private-ips` (anti-SSRF — ver acima). |

## Segurança / operação

- **Nenhuma porta publicada** — `docker port gotenberg` deve ser vazio. Nem
  `127.0.0.1:`, nem tailnet: só quem está na rede `warpgate` alcança
  (regra 2 do AGENTS.md por excesso — não há o que expor).
- **User não-root nativo** da imagem (`gotenberg`, uid/gid 1001 — coincide
  com o `deploy` da VPS) + `no-new-privileges:true`.
- **Healthcheck** nativo `GET /health` (200 up / 503 down) via `curl --fail`
  — regra 4 validada em 2026-07-30: a imagem 8.34.0 tem `curl`
  (`/usr/bin/curl`); `wget`/`nc` ausentes.
- **Stateless, sem volume** — upgrade/rollback é trocar a tag e reaplicar o
  playbook.
- **OOM/crash** cobertos pelo `docker_events_alerter` (#165) → GlitchTip.

## Smoke test (pós-playbook)

```bash
# 1. Health de dentro de um container da warpgate (valida DNS + rede):
docker exec aerobi-api sh -c 'wget -qO- http://gotenberg:3000/health || curl -s http://gotenberg:3000/health'

# 2. Conversão mínima devolve %PDF- (curl da própria imagem do Gotenberg):
docker exec gotenberg sh -c "echo '<html><body>ok</body></html>' > /tmp/index.html && \
  curl -s --fail --form files=@/tmp/index.html \
  -o /tmp/smoke.pdf http://localhost:3000/forms/chromium/convert/html && \
  head -c 5 /tmp/smoke.pdf"   # → %PDF-

# 3. Nenhuma porta publicada:
docker port gotenberg   # deve ser vazio
```

## Troubleshooting

| Sintoma | Causa provável | Fix |
|---|---|---|
| "session deleted because of page crash" | `/dev/shm` pequeno | Conferir `gotenberg_shm_size` (≥ 512M) |
| 503 nas conversões | Fila cheia (`--chromium-max-queue-size`) ou módulo Chromium down (`/health` → 503) | `docker logs gotenberg`; se for carga real sustentada, bumpar a fila/timeout e avaliar segunda instância |
| Container morto por OOM | Estourou `memory: 1g` | Evento chega no GlitchTip (docker_events_alerter); bumpar `gotenberg_memory_limit` no inventory |
| API não alcança `gotenberg:3000` | Containers em redes diferentes | Ambos precisam estar na `warpgate` (`docker inspect <container> --format '{{json .NetworkSettings.Networks}}'`) |
| Timeout em PDFs grandes | `--api-timeout=30s` curto pro documento | Bumpar `gotenberg_api_timeout` (e o timeout do client HTTP na aerobi-api) |

## Uso

```bash
ansible-playbook -i inventory/prod playbooks/setup_gotenberg.yml
```

Após merge + playbook, criar o secret consumido pela `aerobi-api` (a mesma
URL serve staging e prod; se o deploy usar GitHub Environments, criar em
ambos):

```bash
gh secret set GOTENBERG_URL --repo atzaero/aerobi-api --body "http://gotenberg:3000"
```
