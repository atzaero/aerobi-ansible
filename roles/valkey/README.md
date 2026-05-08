# Role: valkey

Sobe [Valkey](https://valkey.io) (fork OSS do Redis mantido pela Linux Foundation) em container Docker na rede `warpgate`. Serviço **interno** — sem vhost público, apps consomem via rede Docker.

## Por que Valkey e não Redis

Drop-in replacement do Redis OSS — mesma API, mesmo wire protocol, mesmos clients (`ioredis`, `node-redis`, `bullmq`). Licença BSD-3, mantido por AWS/Google/Oracle/Ericsson + comunidade. Nasceu do fork Redis 7.2.4 após Redis Labs mudar pra licença não-OSI em mar/2024.

## Segurança

- **`requirepass` obrigatório** — role falha se senha for default `changeme`. Sempre sobrescrever via vault em prod.
- **Bind `127.0.0.1` only** no host — apps acessam via rede Docker `warpgate` (`valkey:6379`), não via internet pública.
- **`no-new-privileges`** herdado do daemon Docker config (setup_vps.yml).
- **User não-root** (1001:1001 = `deploy`).
- Sem TLS — tráfego só na rede Docker, nunca na internet aberta. Adicionar TLS interno tem custo de latência sem ganho real.

## Pré-requisitos

| Role | Por quê |
|---|---|
| `docker` + `docker_network` | Container + rede `warpgate` |

## Variáveis principais

Defaults em `defaults/main.yml`. Obrigatória:

| Var | Onde definir |
|---|---|
| `valkey_password` | `vault.yml` em prod (referenciar via `{{ vault_valkey_password }}` no `all.yml`) |

Comuns sobrescrevidas:

| Var | Default | Descrição |
|---|---|---|
| `valkey_version` | `9.0.3` | Pin da imagem (revisar changelog antes de bumpar) |
| `valkey_port` | `6379` | Porta no host (em 127.0.0.1) |
| `valkey_maxmemory` | `512mb` | Limite de memória |
| `valkey_maxmemory_policy` | `allkeys-lru` | Eviction policy |
| `valkey_aof_enabled` | `"yes"` | AOF persistence |

## Casos de uso (aerobi)

- **Cache**: queries Postgres pesadas da `aerobi-api`, ISR/SSR Next.js, hot data de dashboards.
- **Sessões**: middleware Next.js, futuros apps com cookies stateful.
- **Filas**: BullMQ (jobs assíncronos: notificações, ingest de eventos do aeródromo).
- **Pub/Sub**: comunicação entre serviços rodando no mesmo host.
- **Rate limiting**: contadores por usuário/IP.

## Como conectar (apps)

Apps na rede `warpgate` conectam usando o nome do container como hostname:

```js
// Node.js (ioredis)
const Redis = require('ioredis');
const client = new Redis('redis://default:SENHA@valkey:6379');
```

Valkey aceita o esquema `redis://` por compat — clientes Redis funcionam sem mudança.

### DBs lógicos (16 disponíveis)

Convenção opcional pra separar workloads quando múltiplos consumers existirem:

```js
const cache = new Redis({ host: 'valkey', db: 0 });   // cache aerobi-api
const queue = new Redis({ host: 'valkey', db: 1 });   // BullMQ queues
```

Sem necessidade enquanto for 1 app — qualquer um usa db 0.

## Debug local (na VPS)

```bash
# Senha vem do vault
ansible localhost -m debug -a "var=vault_valkey_password" \
  -e "@inventory/prod/group_vars/all/vault.yml" --connection=local

# REDISCLI_AUTH evita expor senha em argv
ssh deploy@187.127.6.20 "REDISCLI_AUTH=<senha> docker exec -it valkey valkey-cli"

# Status / métricas
docker exec valkey valkey-cli INFO memory | grep used_memory_human
docker exec valkey valkey-cli DBSIZE
docker exec valkey valkey-cli CLIENT LIST
```

## Persistência

Combinação AOF + RDB:

- **AOF (`appendonly.aof`)**: replay de cada write — durabilidade alta, fsync `everysec` perde no máximo 1s em caso de crash.
- **RDB (`dump.rdb`)**: snapshots periódicos do dataset inteiro — útil pra backup/restore rápido. Default: a cada 1h se >=1 mudança, 5min se >=100 mudanças, 1min se >=10000 mudanças.

Ambos os arquivos ficam em `/home/{{ deploy_user }}/valkey/data` (montado como `/data` no container).

## Backup

Estratégia simples: snapshot ao vivo do RDB sem stop:

```bash
ssh deploy@187.127.6.20 "docker exec valkey valkey-cli BGSAVE"
ssh deploy@187.127.6.20 "tar -czf valkey-backup-$(date +%F).tgz -C /home/deploy/valkey data/"
```

Automatizar via cron + upload pra MinIO bucket vira issue futura (compartilhada com backup do Postgres).

## Troubleshooting

| Sintoma | Causa provável | Fix |
|---|---|---|
| `(error) NOAUTH Authentication required` | Tentando acessar sem `requirepass` | Setar `REDISCLI_AUTH` ou usar `-a <senha>` |
| Container restart loop | Owner errado em `valkey_data_dir` | `chown -R 1001:1001 /home/deploy/valkey/data` |
| `OOM` / latência alta | `maxmemory` baixa pro workload | Bumpar `valkey_maxmemory` no inventory |
| Eviction não acontece | Policy `noeviction` ou `volatile-*` sem TTL nas keys | Trocar pra `allkeys-lru` |
| App externo não conecta | Tentando usar `127.0.0.1:6379` de outro container | Usar hostname `valkey` na rede warpgate |
