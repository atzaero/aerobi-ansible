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
| Health endpoint | `GET /server/ok` → `200 {"status":"ok"}` (**público**, sem `apikey`) | `pkg/server/handler/server_handler.go` + `routes.go` (`eng.GET("/server/ok", ...)`) |

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

## Como aplicar (sequência pós-merge, em prod)

Rodar **depois** do merge (regra do repo: `main` reflete o estado real da VPS).

```bash
# 1. Segredos no vault (uma vez) — ver inventory/.../all.yml (seção Evolution GO):
#    vault_evolution_go_db_password, vault_evolution_go_api_key (GLOBAL_API_KEY)

# 2. Bancos + container (idempotente)
ansible-playbook -i inventory/prod playbooks/setup_evolution_go.yml

# 3. DNS A no Registro.br: evolution.aerobi.com.br -> 187.127.6.20 (aguardar propagar)
dig +short evolution.aerobi.com.br @1.1.1.1

# 4. Extra DNS record do Headscale (já em roles/headscale/defaults/main.yml) -> reaplicar
ansible-playbook -i inventory/prod playbooks/setup_headscale.yml

# 5. Vhost tailnet-only + TLS
ansible-playbook -i inventory/prod playbooks/setup_app.yml \
  -e "app_name=evolution_go app_domain=evolution.aerobi.com.br \
      app_port=4000 vhost_tailnet_only=true vhost_websocket_enabled=true"
```

## ⚠️ Licença / ativação (gate confirmado em prod)

A Evolution GO é **Apache 2.0 (com condições de marca)**, mas **exige ativação de
licença para operar**: a API responde **`503 LICENSE_REQUIRED`** até ser ativada
(`GET /` → `{"code":"LICENSE_REQUIRED", ... "Open the manager to activate"}`).

- **Ativação** é feita na **tela do manager** (`/manager` → `/manager/login`):
  informa a **API URL** e a **`GLOBAL_API_KEY`** (= `vault_evolution_go_api_key`)
  e completa o fluxo de registro. Recuperar a chave:
  `ansible localhost -m debug -a "var=vault_evolution_go_api_key" -e "@inventory/prod/group_vars/all/vault.yml" --connection=local`.
- O README **não informa preço** (grátis/trial/pago). Licenciamento:
  `suporte@evofoundation.com.br`. **Confirmar a viabilidade comercial antes de
  depender disso em produção** — sem ativação, o `POST /send/text` não funciona.

## Gotchas de deploy (validados em prod)

- **`SERVER_PORT` deve ser string** no env do `docker_container`. `evolution_go_port`
  é int e o `community.docker.docker_container` rejeita env não-string
  ("Ambiguous env options must be wrapped in quotes"). Fix: `"{{ evolution_go_port | string }}"`.
- **Manager UI em `/manager`** (login `/manager/login`); `/` retorna 503 enquanto não ativado.
- **Pull da imagem pode dar timeout no 1º apply** — se o `docker_container` falhar no
  pull, fazer `docker pull evoapicloud/evolution-go:<tag>` na VPS e reaplicar.

## Pendência: linkar o número (#143 — passo manual)

Exige o **celular físico do número de WhatsApp do negócio** (escanear QR uma vez):

1. Criar instância (apikey = `GLOBAL_API_KEY`):
   `POST /instance/create` `{"name":"aerobi","token":"<token-da-instancia>"}`
   — guardar o `token` no vault como `vault_evolution_go_instance_token`.
2. Conectar e pegar o QR (apikey = token da instância):
   `POST /instance/connect` → `GET /instance/qr` (ou pelo manager em
   `https://evolution.aerobi.com.br`, via tailnet).
3. Escanear o QR no WhatsApp do número (Aparelhos conectados).
4. Validar envio real: `POST /send/text` `{"number":"55...","text":"teste"}`.
5. Repassar o `token` da instância à aerobi-api como `EVOLUTION_GO_API_KEY`
   (aerobi-api#304) — via secret, nunca em texto claro.

**Recuperação de sessão:** a sessão vive no DB `evolution_go_auth`. Restaurar o
backup do Postgres restaura a sessão. Só é preciso reescanear o QR se o número for
deslogado no celular ou o DB `evolution_go_auth` for perdido.
