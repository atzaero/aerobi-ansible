# Role: `glitchtip`

Sobe o **GlitchTip 6** (error tracking self-hosted, compatível com SDKs Sentry)
via Docker na rede `warpgate`, com bind em `127.0.0.1`. Backend de erros da
`aerobi-api` (`atzaero/aerobi-api#131`) e do `aerobi-web` (`atzaero/aerobi#1239`)
— issue de infra: `atzaero/aerobi-ansible#27`.

Container **único** `all_in_one` (web + worker django-vtasks + migrações no
boot). Fila e cache vivem no **próprio Postgres** (`VALKEY_URL` vazio) — sem
Valkey. A exposição HTTP/TLS **não** é feita aqui — é vhost **público** via
`setup_app.yml` (ver `playbooks/setup_glitchtip.yml`): o SDK do browser envia
eventos direto do navegador do usuário final para o DSN.

## Pré-requisitos

- Docker + rede `warpgate` (roles `docker`, `docker_network`).
- PostgreSQL rodando (role `postgres`) com o banco `glitchtip` provisionado —
  o playbook `setup_glitchtip.yml` cuida disso via `postgres_databases`.
- Segredos no vault: `vault_glitchtip_db_password`, `vault_glitchtip_secret_key`,
  `vault_glitchtip_smtp_password`.

## Variáveis (`defaults/main.yml`)

| Variável | Default | Descrição |
|---|---|---|
| `glitchtip_image` | `glitchtip/glitchtip` | Imagem (Docker Hub). |
| `glitchtip_version` | `6.2.2` | Tag pinada (releases em glitchtip.com/blog). |
| `glitchtip_container_name` | `glitchtip` | Nome/alias DNS na `warpgate`. |
| `glitchtip_port` | `8000` | Porta no host (`127.0.0.1:<porta>:8000`); container escuta fixo em 8000. |
| `glitchtip_uploads_volume` | `glitchtip_uploads` | Volume `/code/uploads` (sourcemaps/attachments). |
| `glitchtip_db` | `glitchtip` | Banco no Postgres compartilhado. |
| `glitchtip_db_user` | `glitchtip_user` | Usuário Postgres. |
| `glitchtip_domain` | `errors.aerobi.com.br` | Domínio público (a role monta `https://` no `GLITCHTIP_DOMAIN`). |
| `glitchtip_smtp_host/port/username` | Gmail 587 | SMTP STARTTLS (mesmo servidor do Vaultwarden). |
| `glitchtip_from_email` | `admin@aerobi.com.br` | `DEFAULT_FROM_EMAIL`. |
| `glitchtip_enable_user_registration` | `"True"` | **Só até o admin se registrar** — depois flip para `"False"` + re-apply. |
| `glitchtip_enable_organization_creation` | `"False"` | Só superusers criam orgs. |
| `glitchtip_retention_days` | `90` | Retenção de eventos (`GLITCHTIP_RETENTION_DAYS`). |
| `glitchtip_enable_uptime` | `"False"` | Uptime monitoring off (Uptime Kuma já cobre). |
| `glitchtip_enable_logs` | `"False"` | Ingestão de logs off (só errors). |
| `glitchtip_enable_admin` / `_openapi` | `"False"` | `/admin` e `/api/docs` off. |
| `glitchtip_vtasks_concurrency` | `"10"` | Workers asyncio (reduzido: poupa conexões no PG compartilhado). |
| `glitchtip_db_password` | `changeme` | **Override no vault**. Fail-fast se `changeme`. |
| `glitchtip_secret_key` | `changeme` | **Override no vault** (`openssl rand -hex 32`). Fail-fast. |
| `glitchtip_smtp_password` | `changeme` | **Override no vault** (Gmail app password **sem espaços**). Fail-fast. |

## Segurança / operação

- **Bind só em `127.0.0.1`** — exposição via nginx (CLAUDE.md regra 2). Vhost é
  **público** de propósito (ingest de eventos do browser); mitigação: registro
  fechado após setup, orgs só por superuser, retenção 90d.
- Segredos no vault per-value; validação fail-fast e `no_log: true` nas tasks
  que tocam segredo. **Rotação do `SECRET_KEY` invalida sessões** (não DSNs).
- `no-new-privileges:true`, `restart_policy: unless-stopped`.
- **Healthcheck**: `python -c urllib` contra `/_health/` (200 sem auth) —
  curl/wget não são garantidos na imagem python slim (regra 4). `start_period`
  de 90s porque o primeiro boot roda migrações.
- **Fila/cache no Postgres** (`VALKEY_URL=""`): suportado oficialmente, mira
  instâncias pequenas. Se o volume de eventos crescer, subir um Valkey
  **dedicado** com `noeviction` e apontar `VALKEY_URL` — não usar o Valkey
  compartilhado (`allkeys-lru` evicta tarefas de fila).
- **Mudança de env**: o `docker_container` detecta drift e recria o container
  ao reaplicar — é o mecanismo do flip de `ENABLE_USER_REGISTRATION`.
- **Bump de versão**: editar `glitchtip_version` revisando glitchtip.com/blog e
  validando com `docker manifest inspect glitchtip/glitchtip:<tag>`.
- **Conexões no PG**: medir após deploy com
  `docker exec postgres psql -U postgres -c "select usename, count(*) from pg_stat_activity group by 1;"`.

## Primeiro acesso (runbook)

1. Vhost público (depois deste playbook — DNS propagado antes):
   ```bash
   ansible-playbook playbooks/setup_app.yml \
     -e "app_name=glitchtip app_domain=errors.aerobi.com.br app_port=8000 \
         vhost_client_max_body_size=50m"
   ```
2. Registrar o **admin** em `https://errors.aerobi.com.br` (primeiro usuário).
3. Flip `glitchtip_enable_user_registration: "False"` no inventory →
   re-aplicar `setup_glitchtip.yml` → commitar o flip.
4. Na UI: criar org `aerobi`; projetos `aerobi-api` (platform Node) e
   `aerobi-web` (platform JavaScript). Copiar os DSNs para os GitHub
   Environments `staging`/`production`: secret `SENTRY_DSN` no `atzaero/aerobi-api`
   e `NEXT_PUBLIC_SENTRY_DSN` no `atzaero/aerobi` (lá é build-arg).
5. Monitor no Uptime Kuma: HTTP `https://errors.aerobi.com.br/_health/`.
6. Testar e-mail:
   ```bash
   docker exec glitchtip ./manage.py sendtestemail seu@email.com
   ```

## Uso

```bash
ansible-playbook -i inventory/prod playbooks/setup_glitchtip.yml
```
