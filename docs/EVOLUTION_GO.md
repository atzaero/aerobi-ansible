# Evolution GO — superfície confirmada (spike #137 / #138)

API de WhatsApp em Go (whatsmeow) que a `aerobi-api` (epic `atzaero/aerobi-api#304`)
consome para notificar coordenadores quando um *movement* é criado.

> **Status:** fatos confirmados contra a fonte oficial em 2026-06-15. Esta é a doc
> de referência canônica do serviço; procedimentos operacionais (linkar número,
> recuperar sessão) entram com a #143.

## Fonte da verdade

- Repositório: <https://github.com/evolution-foundation/evolution-go> (ref `0f9ef30`, `VERSION` = **0.7.1**).
- Wiki oficial: `docs/wiki/` do próprio repo + <https://doc.evolution-api.com>.
- Imagem: **Docker Hub `evoapicloud/evolution-go`** — tags `0.7.1` e `latest`
  publicadas em 2026-05-08 (`0.7.1` casa com o `VERSION`). **Pinamos `0.7.1`**
  (mesma política do vaultwarden; nunca `latest` em prod).

## Resumo da superfície

| Item | Valor confirmado | Evidência |
|---|---|---|
| Imagem | `evoapicloud/evolution-go:0.7.1` | Docker Hub + `VERSION` |
| Porta HTTP | `SERVER_PORT` (sem default no código — **obrigatório setar**); exemplos de prod usam **4000** | `cmd/evolution-go/main.go`: `Addr: ":" + os.Getenv("SERVER_PORT")` |
| Header de auth | **`apikey`** | `pkg/middleware/auth_middleware.go`: `ctx.GetHeader("apikey")` |
| Banco | **PostgreSQL obrigatório**, 2 DSNs (auth + users) | `pkg/config/config.go` `Load()` |
| Redis/Valkey | **Não usa** | ausente em `env.go`/`go.mod` |
| AMQP/RabbitMQ, NATS | Opcionais (desabilitados por padrão) | `AMQP_URL`/`NATS_URL` vazios |
| MinIO/S3 | Opcional (`MINIO_ENABLED=false`), só p/ mídia | `loadMinioConfig` só roda se `MINIO_ENABLED=true` |
| Sessão WhatsApp | **Persiste no Postgres** (whatsmeow `sqlstore`), **não** em volume de arquivo | `pkg/whatsmeow/service/whatsmeow.go`: `sqlstore.Container` |
| Manager UI + Swagger | Embutidos na imagem (`/manager/dist`, `/swagger/index.html`) | `Dockerfile` |

## Autenticação — dois níveis (header `apikey` em ambos)

1. **`GLOBAL_API_KEY`** (env, **obrigatória** — o app dá `LogFatal` se vazia):
   operações administrativas → criar/listar/deletar instância.
2. **Token da instância** (definido no `POST /instance/create`, campo `token`):
   operações da instância → conectar, QR, **enviar mensagem**.

Ou seja, a `aerobi-api` precisa de **dois segredos**: a `GLOBAL_API_KEY` (só para
administrar) e o **token da instância** (para o `sendText` do dia a dia).

## Banco de dados

Duas connection strings completas (DSN), apontando para o Postgres da `warpgate`:

```
POSTGRES_AUTH_DB  = postgresql://<user>:<pass>@postgres:5432/evolution_go_auth?sslmode=disable
POSTGRES_USERS_DB = postgresql://<user>:<pass>@postgres:5432/evolution_go_users?sslmode=disable
DATABASE_SAVE_MESSAGES = "false"   # obrigatória; "false" = não armazenamos mensagens
```

- `evolution_go_auth` guarda credenciais/**sessão do WhatsApp** (whatsmeow) e a
  licença. `evolution_go_users` guarda instâncias/usuários (GORM).
- O app tenta **auto-criar** o DB que faltar (`ensureDBExists` conecta no DB
  `postgres`). **Pré-criamos** ambos via role `postgres_databases` (menor
  privilégio — o user não precisa de `CREATEDB`).
- `sslmode=disable` é aceitável: tráfego container↔container na rede `warpgate`.
- **Backup da sessão = backup do Postgres.** Recriar o container **não** desloga o
  WhatsApp; só perderia a sessão se o DB `evolution_go_auth` fosse destruído.

## Endpoints (consumidos pela aerobi-api)

Base interna (warpgate): `http://<container>:<SERVER_PORT>`. Todos exigem header `apikey`.

| Ação | Método + path | `apikey` | Body |
|---|---|---|---|
| Criar instância | `POST /instance/create` | `GLOBAL_API_KEY` | `{"name":"<instancia>","token":"<token-da-instancia>"}` |
| Conectar / QR | `POST /instance/connect` e `GET /instance/qr` | token da instância | — |
| **Enviar texto** | **`POST /send/text`** | token da instância | `{"number":"55DDXXXXXXXXX","text":"..."}` |

> ⚠️ **Correção importante p/ o adapter:** o endpoint de envio é **`POST /send/text`**
> (confirmado em `docs/wiki/guias-api/api-messages.md`, `quickstart.md` e
> `conceitos-core/instances.md`). **NÃO** é `/message/sendText` (esse é da Evolution
> API v2 em Node, projeto diferente). `number` = DDI+DDD+número, só dígitos.

## Variáveis de ambiente que vamos setar (mínimo para notificações de texto)

| Env | Valor | Origem |
|---|---|---|
| `SERVER_PORT` | `4000` | default de prod do upstream |
| `GLOBAL_API_KEY` | `{{ vault_evolution_go_api_key }}` | vault per-value |
| `POSTGRES_AUTH_DB` | DSN p/ `evolution_go_auth` | montado da senha do vault |
| `POSTGRES_USERS_DB` | DSN p/ `evolution_go_users` | montado da senha do vault |
| `DATABASE_SAVE_MESSAGES` | `"false"` | obrigatória |
| `CLIENT_NAME` | `aerobi` | identificador |
| `CONNECT_ON_STARTUP` | `"true"` | reconecta a instância ao subir |
| `LOG_DIRECTORY` | `/app/logs` | volume de logs |
| `MINIO_ENABLED` / `AMQP_URL` / `NATS_URL` | `false` / vazio / vazio | desabilitados no MVP |

Volumes (espelham o compose oficial; com Postgres a sessão **não** depende deles,
mas mantemos para logs e estado local): `evolution_go_data:/app/dbdata`,
`evolution_go_logs:/app/logs`.

## Decisão de arquitetura nesta VPS (proposta — a confirmar)

A `aerobi-api` roda **na mesma VPS, na rede `warpgate`**. Portanto:

- **Exposição pública: nenhuma.** O vhost `evolution.aerobi.com.br` fica
  **tailnet-only** (`vhost_tailnet_only=true` + `headscale_extra_dns_records` →
  `100.64.0.1`), igual a `s3-console`/`status`/`sftp`. Serve só p/ humano
  acessar manager/QR/Swagger via tailnet. A API de envio do WhatsApp (que dispara
  mensagens do número do negócio) **não** vai para a internet.
- **A aerobi-api consome pela rede interna**: `EVOLUTION_GO_BASE_URL=http://evolution_go:4000`
  (sem TLS — tráfego container↔container), **não** pelo domínio público.

Isso respeita a regra estrita #1 (CLAUDE.md) e a postura tailnet-only do repo
(`docs/PORTAS.md → endpoints tailnet-only`).

## Contrato para o adapter da aerobi-api (#304)

| Config no adapter | Valor |
|---|---|
| `EVOLUTION_GO_BASE_URL` | `http://evolution_go:4000` (warpgate interno) |
| `EVOLUTION_GO_API_KEY` | token **da instância** (não a global) p/ enviar texto |
| `EVOLUTION_GO_INSTANCE` | nome da instância (ex.: `aerobi`) |
| Header de auth | `apikey: <EVOLUTION_GO_API_KEY>` |
| Envio | `POST /send/text` com `{"number":"55...","text":"..."}` |

## Itens em aberto (próximas subs)

- #139 role `evolution_go` (container/warpgate/volume/healthcheck/no-new-privileges).
- #140 DBs `evolution_go_auth` + `evolution_go_users` + segredos
  `vault_evolution_go_db_password`, `vault_evolution_go_api_key`.
- #141 playbook `setup_evolution_go.yml` + inventory (`evolution_go_port: 4000`).
- #142 vhost tailnet-only + Certbot + DNS A + extra_records do Headscale.
- #143 criar instância, escanear QR (1x, exige o celular do número), validar
  `POST /send/text` ponta a ponta; documentar recuperação de sessão.
