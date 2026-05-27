# Role: forgejo

Sobe o [Forgejo](https://forgejo.org) (fork comunitário do Gitea — Git forge self-hosted com Actions e registry OCI embutido) em container Docker na rede `warpgate`. Exposto publicamente sob `git.aerobi.com.br` via `nginx_vhost` + Certbot.

Decisão arquitetural completa em [`docs/research/forgejo.md`](../../docs/research/forgejo.md) (issue #96). Execução: issue #100.

## Por que Forgejo (e não Gitea/GitLab)

GitLab CE consome 4+ GB de RAM baseline — não cabe na VPS compartilhada. Forgejo e Gitea são equivalentes; Forgejo ganha pela governança comunitária e por ler `.github/workflows` direto (migração de CI quase zero-touch a partir do GitHub Actions).

## Reaproveitamento de infra (não duplica componentes)

- **PostgreSQL**: reusa o `postgres` existente na `warpgate`. Banco dedicado provisionado via `postgres_apps` (role `postgres_databases`).
- **Cache**: reusa o `valkey` existente, **DB index 3**, **só cache** (descartável).
- **Sessão**: no **PostgreSQL**, não no Valkey — o `valkey` roda `maxmemory-policy allkeys-lru` e despejaria sessões de login (ver research §6).
- **Registry de container**: embutido no Forgejo (`/v2`) — sem container separado.
- **Reverse proxy**: nginx host-based existente, via `setup_app.yml`.

## Segurança

- **Bind `127.0.0.1` only** no host (porta 3020) — acesso externo só via Nginx (regra 2 do `CLAUDE.md`).
- **Banco dedicado** (não SQLite); senha via vault, validação fail-fast.
- **`SECRET_KEY`/`INTERNAL_TOKEN`** auto-gerados pelo Forgejo no primeiro boot e **persistidos no volume** — não ficam no vault nem no inventory.
- **Cadastro fechado** (`DISABLE_REGISTRATION`) + **exige login** (`REQUIRE_SIGNIN_VIEW`).
- **SSH-git desabilitado** nesta fase (git via HTTPS + Personal Access Token). SSH é fase 2.
- **`no-new-privileges`** no container.
- Imagem **normal** (não `-rootless`): inicia como root (s6 init) e dropa para `USER_UID`/`USER_GID` (1001 = `deploy`). Por isso **não** se define `user:` no container.

## Pré-requisitos

| Item | Por quê |
|---|---|
| `docker` + `docker_network` | Container + rede `warpgate` |
| `postgres` rodando + banco `forgejo` | Persistência (provisionado por `postgres_databases`) |
| `valkey` rodando | Cache |
| `nginx` instalado | vhost emitido depois via `setup_app.yml` |
| DNS `git.aerobi.com.br` → IP da VPS | Necessário para o Certbot (HTTP-01) |

## Variáveis principais

Defaults em `defaults/main.yml`. Obrigatórias em prod (via vault):

| Var | Onde definir |
|---|---|
| `forgejo_db_password` | `all.yml` → `{{ vault_forgejo_db_password }}` |
| `forgejo_admin_password` | `all.yml` → `{{ vault_forgejo_admin_password }}` |
| `valkey_password` | já compartilhado com a role `valkey` |

Demais: `forgejo_version` (pin), `forgejo_domain`, `forgejo_http_port` (3020), `forgejo_data_dir`, flags de segurança.

## Como aplicar

```bash
# 1. Provisiona DB + sobe container (após DNS + vault prontos)
ansible-playbook -i inventory/prod playbooks/setup_forgejo.yml

# 2. Expõe via nginx + TLS (websocket + uploads grandes p/ git push/LFS/registry)
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=forgejo app_domain=git.aerobi.com.br app_port=3020 \
      vhost_websocket_enabled=true vhost_client_max_body_size=1g"
```

Depois: acesse `https://git.aerobi.com.br`, faça login com `forgejo_admin_user` / `vault_forgejo_admin_password`, crie a organização e o primeiro repositório.

## Não coberto nesta role (follow-ups)

- **Forgejo Runner** (CI) — PR próprio (`roles/forgejo_runner`, DinD isolado).
- **SSH-git** em porta dedicada + UFW — fase 2.
- **Migração de repos/issues** do GitHub (`gitea migrate` / push-mirror).
- **Backup** do DB + data dir para MinIO — integrar ao padrão de backups.
