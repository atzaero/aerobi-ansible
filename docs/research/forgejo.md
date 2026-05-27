# Research: auto-hospedagem de Git + CI na VPS Aerobi

**Tipo:** Research / Spike — comparar, decidir, gerar issue de implementação se aprovado.

**Status:** Concluído. Recomendação: **Forgejo** containerizado, reusando o `postgres` e o `valkey` existentes na rede `warpgate`, exposto via `nginx_vhost` + Certbot sob `git.aerobi.com.br`. Runner de CI dockerizado (DinD isolado). Sem Traefik, sem Postgres/Redis/Registry novos.

**Referência:** entregável da issue [atzaero/aerobi-ansible#96](https://github.com/atzaero/aerobi-ansible/issues/96). Surgiu durante a migração do `aerobi-web` (#95/#93), quando o GitHub Actions foi bloqueado por billing e o deploy teve que ser manual.

---

## 1. Motivação

O GitHub Actions ficou bloqueado por billing, travando CI e deploy do `aerobi-web` — deploy manual como contorno. Isso expõe uma dependência de custo/disponibilidade externa num ponto crítico do fluxo. Auto-hospedar Git + CI na própria VPS remove essa dependência, mantém o código e os pipelines sob controle, e abre caminho para registry de container próprio (hoje GHCR).

A restrição forte é o ambiente: a VPS (`187.127.6.20`, 16 GB) **já é compartilhada** por postgres, valkey, minio, vaultwarden, sftpgo, uptime-kuma, headscale, mediamtx, aerobi-web e aerobi-api. Qualquer solução precisa caber nesse orçamento de recursos sem degradar a produção.

## 2. Decisão de ferramenta (Forgejo vs Gitea vs GitLab)

| Critério | Forgejo | Gitea | GitLab CE |
|---|---|---|---|
| RAM baseline | ~150–300 MB | ~150–300 MB | **4+ GB** |
| CI nativo | Forgejo Actions (lê `.github/workflows` e `.forgejo/workflows`) | Gitea Actions (mesma base `act`) | GitLab CI (sintaxe própria) |
| Registry embutido | Sim (OCI) | Sim (OCI) | Sim |
| Migração de `ci.yml`/`release.yml` | Quase zero-touch (compat. GitHub Actions) | Igual | **Reescrita total** |
| Governança | Comunitária (Codeberg e.V.) | Empresa (Gitea Ltd.) | Empresa |

**Decisão: Forgejo.** GitLab CE está fora — sozinho consome mais RAM que toda a stack atual somada. Gitea e Forgejo são tecnicamente equivalentes hoje; Forgejo ganha pela governança comunitária (motivo do fork) e por ser o alvo explícito da issue. O fator decisivo prático é a compatibilidade com workflows do GitHub Actions: migrar `ci.yml`/`release.yml` do `aerobi-web`/`aerobi-api` com retoque mínimo.

## 3. Reaproveitamento da infraestrutura existente

A stack aerobi já resolve, de forma própria, vários componentes que um guia genérico de Forgejo mandaria instalar do zero. Decisões para o nosso contexto:

| Componente genérico | Decisão aerobi | Justificativa |
|---|---|---|
| Traefik | ❌ Descartar | Viola regra 3 do `CLAUDE.md`. Nginx host-based + Certbot + `nginx_vhost` já é o padrão. Dois proxies = conflito de 80/443. |
| PostgreSQL em container novo | ❌ Reusar `postgres` da `warpgate` | Já containerizado. Forgejo vira item em `postgres_apps` (role `postgres_databases`). |
| Redis containerizado | ⚠️ Reusar `valkey`, só cache | Ver §6 — `maxmemory-policy: allkeys-lru` pode despejar sessões. |
| Registry separado | ❌ Registry embutido do Forgejo | Forgejo serve OCI em `/v2`. Zero container extra. |
| Prometheus + Grafana + Loki | ⚠️ Adiar | Pesado p/ VPS compartilhada. Forgejo expõe `/metrics`; uptime-kuma já cobre health. Ver §10. |
| Ambientes dev/staging/prod | ❌ Só `prod` | Repo tem apenas `inventory/prod`. |
| Layout `/data/forgejo` | ❌ `/home/{{ deploy_user }}/forgejo/data` | Convenção do repo (ver `valkey_data_dir`). |
| UFW / fail2ban / SSH hardening | ✅ Já existem como roles | Só adicionar regra UFW se habilitarmos SSH-git (§7). |
| MCP Server | ⚠️ Preparar PAT, adiar container | `forgejo-mcp` é fase 2. |

**Resultado:** o Compose do Forgejo carrega **só 2 containers** — `forgejo` + `runner`. Nada de postgres, redis, traefik, registry ou observabilidade no compose.

## 4. Arquitetura final

```
                  Internet
                     │  443/TLS (Certbot)
              ┌──────▼───────┐  host-based (role nginx)
              │    nginx     │  vhost git.aerobi.com.br
              └──────┬───────┘  websocket + client_max_body_size 1g
                     │ proxy_pass 127.0.0.1:3000
        ┌────────────▼─────────────────── rede warpgate ──────────┐
        │  ┌──────────┐   ┌──────────┐   ┌──────────┐              │
        │  │ forgejo  │──►│ postgres │   │  valkey  │ (cache only) │
        │  │  :3000   │   │  :5432   │◄──┘  :6379                  │
        │  └────┬─────┘   └──────────┘                             │
        └───────┼──────────────────────────────────────────────────┘
                │ rede forgejo_runner (isolada)
          ┌─────▼──────┐
          │   runner   │ → spawna containers de job (mem/cpu limit)
          └────────────┘
```

- **Forgejo**: bind `127.0.0.1:3000` (regra 2). DB em `postgres`, cache em `valkey`. Volume `/home/{{ deploy_user }}/forgejo/data` (repos, LFS, packages/registry).
- **Registry**: embutido, mesmo domínio (`git.aerobi.com.br/<org>/<img>`).
- **Runner**: rede própria; fala com Forgejo por `http://forgejo:3000` interno.
- **Acesso**: **público com TLS** (não tailnet-only) — Forgejo precisa ser alcançável por git clients e por CI. Harden por config (registro fechado, 2FA), não por rede. Alternativa: começar `vhost_tailnet_only=true` + extra DNS record no Headscale (regra 1) e abrir depois.

## 5. Footprint e o único risco real de recursos

O Forgejo em si é desprezível (~200 MB). **O risco é o runner de CI**, não o git server. Um `npm build` ou `docker build` do `aerobi-web` pode picar 2–4 GB e saturar CPU, competindo com o `postgres` que serve produção.

Mitigações (entram nos defaults da role):
- `--max-parallelism 1` no início (1 job por vez).
- `mem_limit`/`cpus` nos containers de job.
- Fase 2: runner dedicado num segundo host (não a Raspberry do aeródromo — é ARM e dedicada às câmeras).

## 6. ⚠️ Gotcha do Valkey (ponto mais importante)

O `valkey` atual roda `maxmemory 512mb` + `maxmemory-policy allkeys-lru`. Sob pressão de memória, **qualquer** chave pode ser despejada — inclusive sessões de login do Forgejo, deslogando usuários.

**Recomendação:**
- **CACHE** → Valkey, DB index dedicado (`redis://:senha@valkey:6379/3`). Cache é descartável; LRU não machuca.
- **SESSION** → manter no **PostgreSQL** (`db`) ou cookie. **Não** no Valkey.
- **QUEUE** → default `level` (LevelDB local). Migrar p/ Valkey só se a fila crescer.

Conclusão correta para o nosso contexto: *usar menos Valkey do que um guia genérico pediria*, por causa da política de eviction compartilhada.

## 7. CI / Runner — topologia e segurança

- **Runner dockerizado** (`code.forgejo.org/forgejo/runner`), registrado com token via vault (`vault_forgejo_runner_token`).
- **Acesso a Docker nos jobs**:
  - (a) montar `docker.sock` → simples, mas dá root no host a qualquer job. **Risco alto** numa VPS que serve produção.
  - (b) **Docker-in-Docker** isolado, rede própria → **recomendado**.
- **SSH-git**: expor sem violar regra 2 (nada de `docker -p` público) → built-in SSH em porta dedicada + UFW, ou começar **só HTTPS+PAT** e adiar SSH para fase 2.
- **Migração dos workflows**: Forgejo lê `.github/workflows` direto. Ajustes: re-cadastrar secrets, `runs-on` com labels do runner, GHCR → registry interno.

## 8. Migração do GitHub (transição segura)

1. **Espelho**: push-mirror GitHub → Forgejo (`aerobi-web`, `aerobi-api`, `aerobi-ansible`). GitHub canônico, Forgejo valida.
2. **Migração rica**: `gitea migrate` importa issues/PRs/labels/milestones via API com token do GitHub.
3. **Cutover**: flip do `origin`, CI no Forgejo Runner, GHCR → registry interno.
4. Manter GitHub como mirror passivo de DR.

## 9. Backups (integrado ao padrão MinIO + snapshots)

- `pg_dump` do DB `forgejo` (não global) + `tar` de `/home/{{ deploy_user }}/forgejo/data` (repos, LFS, packages).
- Push pro **MinIO** (bucket `forgejo-backups`) + snapshot Hostinger semanal.
- Retenção: diário 7d / semanal 4w / mensal 3m.
- `forgejo dump` serve p/ backup pontual/migração, não como estratégia diária (zipa tudo, fica pesado).

## 10. Observabilidade (leve, alinhada ao repo)

- **Agora**: `/metrics` nativo do Forgejo + monitor no **uptime-kuma** (já temos) em `https://git.aerobi.com.br/api/healthz`. Zero container novo.
- **Adiar** Prometheus/Grafana/Loki: montar só quando 2+ serviços justificarem scraping central. Deixar `ENABLE_METRICS` ligado na `app.ini` desde já.

## 11. Esboço da role `roles/forgejo/`

Estrutura seguindo o padrão do repo:

```
roles/forgejo/
├── defaults/main.yml      # versão pinada, portas, domínio, flags de feature
├── templates/
│   ├── docker-compose.yml.j2
│   └── app.ini.j2         # config principal do Forgejo
├── tasks/main.yml         # validação fail-fast + diretórios + compose up
├── handlers/main.yml      # restart forgejo
└── README.md
```

`defaults/main.yml` (trechos-chave):
```yaml
forgejo_version: "11.0"          # pinar; bump major = ler release notes
forgejo_domain: git.aerobi.com.br
forgejo_http_port: 3000          # bind 127.0.0.1
forgejo_data_dir: "/home/{{ deploy_user }}/forgejo/data"
docker_network_name: warpgate

forgejo_db_host: "postgres:5432"
forgejo_db_name: forgejo
forgejo_db_user: forgejo
forgejo_db_password: changeme    # vault: vault_forgejo_db_password

forgejo_cache_adapter: redis
forgejo_cache_conn: "redis://:{{ valkey_password }}@valkey:6379/3"
forgejo_session_provider: db     # sessão no postgres, NÃO no valkey (§6)

forgejo_disable_registration: true
forgejo_require_signin: true
```

Integração com o que já existe (sem reinventar):
- **DB** — adicionar em `inventory/prod/group_vars/all/all.yml`:
  ```yaml
  postgres_apps:
    - { name: forgejo, db: forgejo, user: forgejo, password: "{{ vault_forgejo_db_password }}" }
  ```
  e rodar `playbooks/setup_app_databases.yml`.
- **vhost** — `ansible-playbook playbooks/setup_app.yml -e "app_name=forgejo app_domain=git.aerobi.com.br app_port=3000 vhost_websocket_enabled=true vhost_client_max_body_size=1g"`.
- **vault** — `vault_forgejo_db_password` e `vault_forgejo_runner_token` (header do `vault.yml`).
- **playbook** — `playbooks/setup_forgejo.yml`, espelhando `setup_vaultwarden.yml`.

## 12. MCP / IA (fase 2)

Preparar o PAT de serviço e documentar; subir `forgejo-mcp` depois, container em rede interna apontando `http://forgejo:3000`. Casos: triagem de issues, sumário de PR, análise de incidente cruzando com `docs/INCIDENT_RESPONSE.md`. Não bloqueia o MVP.

## 13. Roadmap evolutivo

1. **MVP**: Forgejo + DB no postgres + cache Valkey + vhost nginx + 1 runner DinD. Mirror do GitHub.
2. **CI real**: migrar `aerobi-web`/`aerobi-api`, registry interno, secrets.
3. **Hardening + DR**: backups MinIO automatizados, 2FA obrigatório, SSH-git em porta dedicada (UFW).
4. **Observabilidade**: Prometheus/Grafana só se a stack crescer.
5. **IA**: forgejo-mcp + automações.

## 14. Riscos e gargalos

- **Runner saturando a VPS de produção** (maior risco) → limite de paralelismo + mem/cpu, ou runner dedicado.
- **Eviction de sessão no Valkey compartilhado** → sessão no Postgres (§6).
- **Acoplamento ao postgres de produção** → backup independente + monitorar `max_connections` (hoje 100, folga ok).
- **SSH-git** → expor sem violar regra 2; começar HTTPS+PAT.

## 15. Checklists

**Produção:**
- [ ] `vault_forgejo_db_password` no vault; DB provisionado via `postgres_apps`
- [ ] DNS `git.aerobi.com.br` → IP da VPS propagado (`dig +short ... @1.1.1.1`)
- [ ] vhost com websocket + `client_max_body_size 1g`; TLS emitido
- [ ] Forgejo bind `127.0.0.1:3000`; registro fechado; 2FA
- [ ] Runner com paralelismo/mem limitados; DinD isolado
- [ ] Backup MinIO testado; monitor no uptime-kuma

**Disaster recovery:**
- [ ] Restore do `pg_dump forgejo` num DB limpo valida
- [ ] Restore do `tar` do data dir reabre repos + LFS + registry
- [ ] Mirror no GitHub íntegro como fallback
- [ ] Runbook de restore em `docs/`

## 16. Próximos passos

Após aprovação deste research, abrir **issue de implementação** cobrindo:

1. Role Ansible `roles/forgejo/` (container + `app.ini` + compose) reusando `postgres`/`valkey`.
2. Item `forgejo` em `postgres_apps` + `vault_forgejo_db_password`.
3. vhost via `setup_app.yml` (websocket + body size grande) + DNS `git.aerobi.com.br`.
4. Role/serviço do Forgejo Runner (DinD isolado, paralelismo limitado, `vault_forgejo_runner_token`).
5. `playbooks/setup_forgejo.yml` + entrada em `docs/ROLES.md`/`docs/PORTAS.md`.
6. Backup do DB + data dir para MinIO + retenção; monitor no uptime-kuma.
7. (Fase 2) SSH-git, migração de repos/issues do GitHub, forgejo-mcp.

---

**Tempo estimado de implementação:** 4–6h para o MVP (role + vhost + DB + 1 runner + PoC de push/clone/CI). Migração de repos e SSH-git em fase posterior.
