# Role: `evolution_go`

Sobe a **Evolution GO** (API de WhatsApp em Go / whatsmeow) via Docker na rede
`warpgate`, com bind em `127.0.0.1`. Consumida pela `aerobi-api` para notificar
coordenadores quando um *movement* é criado (`atzaero/aerobi-api#304`).

Superfície da API e contrato do adapter: [`docs/EVOLUTION_GO.md`](../../docs/EVOLUTION_GO.md).
A exposição HTTP/TLS **não** é feita aqui — é tailnet-only via `setup_app.yml`
(ver `playbooks/setup_evolution_go.yml`).

## Pré-requisitos

- Docker + rede `warpgate` (roles `docker`, `docker_network`).
- PostgreSQL rodando (role `postgres`) com os bancos `evolution_go_auth` e
  `evolution_go_users` provisionados — o playbook `setup_evolution_go.yml` cuida
  disso via `postgres_databases`.
- Segredos no vault: `vault_evolution_go_db_password`, `vault_evolution_go_api_key`.

## Variáveis (`defaults/main.yml`)

| Variável | Default | Descrição |
|---|---|---|
| `evolution_go_image` | `evoapicloud/evolution-go` | Imagem (Docker Hub). |
| `evolution_go_version` | `0.7.1` | Tag pinada (casa com o `VERSION` do upstream). |
| `evolution_go_container_name` | `evolution_go` | Nome/alias DNS na `warpgate` (a aerobi-api conecta em `http://evolution_go:<porta>`). |
| `evolution_go_port` | `4000` | `SERVER_PORT` interno **e** bind no host (`127.0.0.1:<porta>:<porta>`). O app não tem default — setar é obrigatório. |
| `evolution_go_data_volume` | `evolution_go_data` | Volume `/app/dbdata` (estado local; a sessão fica no Postgres). |
| `evolution_go_logs_volume` | `evolution_go_logs` | Volume `/app/logs`. |
| `evolution_go_auth_db` | `evolution_go_auth` | DB de auth/sessão (whatsmeow). |
| `evolution_go_users_db` | `evolution_go_users` | DB de instâncias/usuários (GORM). |
| `evolution_go_db_user` | `evolution_go_user` | Usuário Postgres (dono dos dois DBs). |
| `evolution_go_client_name` | `aerobi` | `CLIENT_NAME`. |
| `evolution_go_connect_on_startup` | `"true"` | Reconecta a instância ao subir. |
| `evolution_go_database_save_messages` | `"false"` | Não armazena histórico de mensagens. |
| `evolution_go_db_password` | `changeme` | **Override no vault** (`vault_evolution_go_db_password`). Fail-fast se `changeme`. |
| `evolution_go_api_key` | `changeme` | **Override no vault** (`vault_evolution_go_api_key`) — é o `GLOBAL_API_KEY`. Fail-fast se `changeme`. |

## Segurança / operação

- **Bind só em `127.0.0.1`** — exposição via nginx tailnet-only (CLAUDE.md regra 2).
- `GLOBAL_API_KEY` e senha do banco no vault per-value; validação fail-fast e
  `no_log: true` nas tasks que tocam segredo.
- `no-new-privileges:true`, `restart_policy: unless-stopped`.
- **Healthcheck**: `wget` (busybox, presente na imagem alpine) contra `/server/ok`
  (público, 200). Não usar `curl` — ausente na imagem.
- **Sessão do WhatsApp persiste no Postgres** (DB auth), não em volume → recriar o
  container não desloga; backup do Postgres = backup da sessão.
- **Mudança de env (ex.: rotação do `GLOBAL_API_KEY`)**: o módulo
  `community.docker.docker_container` detecta o drift e recria o container ao
  reaplicar o playbook. Não precisa de restart manual.
- **Bump de versão**: editar `evolution_go_version` revisando os releases do
  upstream e validando com `docker manifest inspect <imagem>:<tag>`. Para um serviço
  que segura a sessão de um número real, considerar pinar por digest `@sha256:...`.

## Uso

```bash
ansible-playbook -i inventory/prod playbooks/setup_evolution_go.yml
```
