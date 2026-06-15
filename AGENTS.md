# AGENTS.md — aerobi-ansible

Fonte **canônica** de contexto pra qualquer agente (Claude, Codex, Cursor, Copilot)
trabalhando neste repo. Documenta só o que **não** dá pra deduzir lendo o código.
O `CLAUDE.md` apenas referencia este arquivo (`@AGENTS.md`) + notas específicas.

## Produto

Automação **Ansible** da infraestrutura aerobi: provisiona uma VPS Hostinger
(Ubuntu 24.04) a partir do zero — hardening base, plataforma de dados (Postgres,
MinIO, Valkey), mesh VPN **Headscale self-hosted**, serviços admin (Vaultwarden,
Uptime Kuma, SFTPGo) atrás de nginx reverse proxy + Let's Encrypt + tailnet, e
edge nodes (Raspberry Pi de aeródromo com MediaMTX RTSP→HLS).

Filosofia: **baseline enxuto**. O repo provê infra; o app de produto (`aerobi-api`)
faz deploy externo via Actions. Ver `README.md → O que este projeto entrega`.

## Stack

| Camada | Tecnologia |
|---|---|
| Orquestração | Ansible (playbooks + roles), inventários dev/dev-aerodrome/prod |
| Runtime | Docker CE, rede compartilhada `warpgate` |
| Proxy/TLS | nginx reverse proxy + Certbot (Let's Encrypt) |
| Dados | PostgreSQL 17, MinIO (S3), Valkey |
| VPN | **Headscale self-hosted** (control plane Tailscale-compatible) + tailscale_client |
| Admin | Vaultwarden, Uptime Kuma, SFTPGo (tailnet-only) |
| Edge | `aerodrome_edge` (Raspberry Pi subnet router) + MediaMTX (RTSP→HLS) |
| Hardening | `ssh_hardening`, `firewall` (UFW deny-default), `fail2ban` |
| Secrets | Ansible Vault **per-value** (não file-level) |
| Teste | `--syntax-check`, `ansible-inventory --list`, Molecule (Docker) |

VPN: **Headscale self-hosted** (diferente do `ansible-vps`, que usa Tailscale SaaS).
O control plane vive **neste repo** — é um alvo de altíssimo valor (ver SECURITY.md).

## Alvos / hosts SSH

| Ambiente | Host | Acesso | Notas |
|---|---|---|---|
| **prod** | `187.127.6.20` (tailnet `100.64.0.1`) | `ssh deploy@187.127.6.20` (key-only) | `deploy` tem `NOPASSWD:ALL` (ver Gotchas) |
| **staging** | co-localizado na prod | via `setup_staging.yml` | mesmo host físico, isolamento lógico |
| **dev** | conforme `inventory/dev/hosts.yml` | — | homologação |
| **edge** | Raspberry Pi (`aerodrome_edge`) | via tailnet | subnet router Tailscale + MediaMTX |

Bootstrap fresh: VPS recém-formatada **não tem `deploy`** ainda → usar
`ansible_user: root` temporário (ver Gotchas + `docs/BOOTSTRAP.md`).

## Arquitetura e pastas

| Área | O que tem |
|---|---|
| `playbooks/` | `setup_vps.yml` (hardening + base), `setup_database.yml`, `setup_app_databases.yml`, `setup_headscale.yml`, `setup_minio.yml`, `setup_vaultwarden.yml`, `setup_valkey.yml`, `setup_uptime_kuma.yml`, `setup_sftpgo.yml`, `setup_postgres_tailnet.yml`, `setup_aerodrome.yml`, `setup_staging.yml`, `setup_app.yml` (vhost+TLS por app) |
| `roles/` | `common`, `user`, `ssh_hardening`, `firewall`, `fail2ban`, `docker`, `docker_network`, `nginx`, `nginx_vhost`, `postgres`, `postgres_databases`, `postgres_tailnet_proxy`, `minio`, `valkey`, `vaultwarden`, `sftpgo`, `sftpgo_tailnet_proxy`, `uptime_kuma`, `headscale`, `tailscale_client`, `mediamtx`, `aerodrome_edge` |
| `inventory/{dev,dev-aerodrome,prod}/` | `hosts.yml` + `group_vars`/`host_vars` (prod usa `group_vars/all/{all.yml,vault.yml}`) |
| `docs/` | runbooks operacionais (ver tabela no fim) |
| `molecule/` | cenário `default` (teste em Docker) |
| `.github/ISSUE_TEMPLATE/automation.md` | template de issue pra automação operacional |

Padrão de role: `defaults/main.yml` (vars + senha default `changeme`),
`tasks/main.yml` (com validação fail-fast de credencial), opcional
`handlers/`, opcional `README.md`.

## Regras estritas

### 1. Toda nova role/serviço com `vhost_tailnet_only=true` precisa de DUAS coisas

1. Vhost criado via `setup_app.yml -e "... vhost_tailnet_only=true"`.
2. Entrada em `headscale_extra_dns_records` (em `roles/headscale/defaults/main.yml`)
   apontando o subdomínio para `100.64.0.1`, **mais** reaplicar
   `playbooks/setup_headscale.yml`.

Sem o passo 2, o cliente resolve o domínio para o IP público, tráfego sai pela
internet, nginx vê o IP público em `$remote_addr` e retorna **403 mesmo com
tailscale up**. Os dois passos são complementares — o vhost filtra, o extra DNS
record força o tráfego do cliente a entrar pela tailnet.

Mecanismo: [`docs/VPN.md → Magic DNS e extra_records`](docs/VPN.md#magic-dns-e-extra_records).
Procedimento: [`docs/DOMINIOS.md → Adicionar um serviço de infra novo`](docs/DOMINIOS.md#adicionar-um-serviço-de-infra-novo).

### 2. Container Docker: bind sempre em `127.0.0.1`, nunca em `0.0.0.0`

Exposição externa é responsabilidade do nginx (com TLS) ou do socat sidecar (para
tailnet). Bind em `0.0.0.0` vaza o serviço para a internet pública mesmo com UFW
deny default — o Docker insere regras `iptables -t nat` avaliadas **antes** do UFW
(issue #7).

### 3. Serviços expostos via tailnet usam socat sidecar com `network_mode: host`

NÃO usar `-p 100.64.0.1:porta:porta` no `docker_container` — mesmo motivo da regra 2
(Docker NAT bypass). Padrão estabelecido em `roles/postgres_tailnet_proxy/` e
`roles/sftpgo_tailnet_proxy/`: container `alpine/socat` separado, `network_mode: host`,
escutando direto na interface `tailscale0`.

### 4. Imagens distroless: usar healthcheck nativo

Várias imagens em uso (drakkan/sftpgo, vaultwarden/server) são distroless — não têm
`curl`, `wget`, `nc`. Antes de definir `healthcheck.test` com utilitários shell,
verificar:

```bash
docker exec <container> sh -c "command -v curl wget nc"
```

Se nada disponível, procurar healthcheck próprio do binário (ex: `sftpgo ping`).

### 5. Secrets sempre em vault, validação fail-fast nas roles

Pattern em `roles/*/defaults/main.yml`: senha default = `changeme`. Pattern em
`roles/*/tasks/main.yml`:

```yaml
- name: Validar senha (não pode estar em 'changeme')
  fail:
    msg: "Adicione vault_<service>_password ao vault antes de aplicar"
  when: <service>_password in ['changeme', '', None]
```

Tasks que manipulam secret usam `no_log: true`. Como adicionar secret novo está
documentado no header do `inventory/prod/group_vars/all/vault.yml`.

**Onde cada variável mora** (não é "tudo no vault"):

- **Secret que um playbook usa** (senha de DB, admin token, API key injetada pela
  role) → **vault per-value deste repo** + fail-fast.
- **Config não-secreta** (domínio, porta, nome de DB/user, container) → `all.yml`
  em texto claro — de propósito, pra ficar legível/diffável no git.
- **Secret consumido por uma app externa** (ex.: token de instância usado só pela
  `aerobi-api`) → **secrets do repo da app** (GitHub Environments), **não** no vault
  daqui — evita drift e mantém o secret junto de quem o consome.

### 6. Merges e operações destrutivas

- Branches: `<tipo>/<num-issue>-<slug>` (ex: `feat/12-sftpgo`, `fix/7-docker-nat`).
- Commits Conventional Commits em **PT-BR** (`feat(escopo): descrição`).
- Base branch: `main` (não `develop`).
- Merge via `gh pr merge --merge --delete-branch` (sem squash, sem rebase, salvo
  pedido explícito).
- **Sempre rodar playbooks em prod DEPOIS do merge**, não antes — garante que `main`
  reflete o estado real da VPS.

### 7. Sempre verificar pré-condições antes de aplicar playbook

Para um serviço novo com vhost:

- DNS no Registro.br propagado (`dig +short <sub>.aerobi.com.br @1.1.1.1`).
- Senha do vault adicionada.
- Se for tailnet-only: extra_records do Headscale **antes** ou **junto** do
  `setup_app.yml` (sem isso, vhost retorna 403 — ver regra 1).
- SSH para `deploy@187.127.6.20` funcional.

## Segurança

Resumo operacional; o threat model completo e o checklist estão em
[`docs/SECURITY.md`](docs/SECURITY.md) — **leitura obrigatória** antes de
`/infra-review` ou `/security-audit`.

Regras invioláveis (detalhe acima em "Regras estritas"):

- **Secrets só no Vault per-value.** Default de senha em role = `changeme` + task
  `fail` fail-fast. `no_log: true` nas tasks com secret.
- **Docker bind sempre `127.0.0.1`** (NAT bypass do UFW — issue #7).
- **Exposição tailnet via socat sidecar** (`network_mode: host`), nunca Docker `-p`.
- **Headscale é control plane** — comprometê-lo dá acesso à tailnet inteira. Tratar
  como crown jewel.
- **Hardening sempre presente**: `ssh_hardening`, `firewall` (UFW deny-default +
  whitelist, inclui UDP 41641 do Tailscale), `fail2ban`.

## Forge (Git hosting)

Este repo vive no **GitHub** (`atzaero/aerobi-ansible`) → usar **`gh` CLI** + MCP
`mcp__github__*`. Branch default: `main`. App relacionado: `atzaero/aerobi-api`.

> **Nota Gitea (portabilidade do template):** alguns repos do ecossistema ficam no
> Gitea self-hosted `git.elvisea.dev`. Nesses casos o tooling troca para **`tea` CLI**
> + API REST `https://git.elvisea.dev/api/v1` (swagger em `/api/swagger`). Diferenças:
> status de Actions usa `success`/`failure` (não `completed`); logs de job via
> `GET /api/v1/repos/{o}/{r}/actions/jobs/{id}/logs`; criar repo de user via
> `POST /api/v1/user/repos`. MCP server do Gitea ainda **não** instalado. **Este repo
> não usa Gitea** — a nota existe só para manter o template portável.

## Gitflow

- **`main`** — único branch de longa vida; cada merge é deploy-ready. Sem `develop`.
- Branches temporárias: `<tipo>/<num-issue>-<slug>` (`feat/`, `fix/`, `chore/`,
  `docs/`) — nascem de `main`, voltam pra `main`. Cada branch tem issue GitHub; o
  número entra no nome.
- **Conventional Commits em PT-BR** (ver `.claude/commands/commit.md`); o tipo do
  commit combina com o tipo do branch. `Closes #N` no corpo (auto-fecha ao mergear).
- Merge via `gh pr merge --merge --delete-branch` (preserva histórico; sem squash).
- **Rodar playbooks em prod só DEPOIS do merge** — garante que `main` reflete o
  estado real da VPS.

## Convenção de domínios

Endpoints públicos seguem regra estrita (ver `docs/DOMINIOS.md`):

- **Infra aerobi** → subdomínios em `aerobi.com.br` (DNS no Registro.br).
- Subdomínios tailnet-only (vault, s3-console, status, sftp) resolvem para
  `100.64.0.1` via `headscale_extra_dns_records` (ver regra 1).

Serviço novo: escolher subdomínio em `aerobi.com.br`, atualizar `docs/DOMINIOS.md`
+ DNS no Registro.br (+ extra_records do Headscale se tailnet-only).

## Vault (per-value encryption)

**Não** é file-level. Cada valor é um bloco `!vault | $ANSIBLE_VAULT;1.1;AES256`
encriptado via `ansible-vault encrypt_string`. Consequências:

- `ansible-vault view <arquivo>` **NÃO funciona** ("Input is not vault encrypted
  data"). Pra decriptar um secret:
  `ansible localhost -m debug -a "var=<nome>" -e "@inventory/prod/group_vars/all/vault.yml" --connection=local`.
- `ansible-vault rekey` **NÃO funciona** — pra rotacionar a master, gerar nova +
  regerar cada bloco individual + substituir no arquivo.
- Senha master em `~/.ansible-vault/aerobi-prod` (fora do working tree, nunca
  commitada). `ansible.cfg` aponta via `vault_password_file`.

Adicionar secret:
```bash
echo -n "$(openssl rand -hex 32)" \
  | ansible-vault encrypt_string --stdin-name 'vault_xxx' \
  >> inventory/prod/group_vars/all/vault.yml
```

O header do `vault.yml` tem o guia operacional completo.

## Gotchas conhecidos

- **NOPASSWD sudoers**: `deploy` precisa de `NOPASSWD:ALL` em
  `/etc/sudoers.d/deploy`. Allowlist restritiva quebra módulos Ansible (rodam
  `python3` como root). Ver `roles/user/tasks/main.yml`.
- **Certbot `--reinstall`**: já configurado em `roles/nginx_vhost/tasks/main.yml`.
  Sem essa flag, em VPS fresh o certbot às vezes emite cert mas o vhost não recebe
  `listen 443 ssl`. Não remover.
- **MinIO `user: uid:gid` = 1001**: container roda como dono do `minio_data_dir`.
  Default 1000:1000; em VPS Hostinger o `deploy` é 1001:1001 — definido em
  `minio_container_uid/gid` no inventory. Mudar = arquivos em `/data` com owner errado.
- **Fresh-bootstrap inventory**: VPS nova não tem `deploy`. Editar
  `inventory/prod/hosts.yml` temporariamente (`ansible_user: root` + comentar
  `ansible_become`), reverter após `setup_vps.yml`. Runbook em `docs/BOOTSTRAP.md`.
- **DNS antes de TLS**: `setup_app.yml` roda certbot HTTP-01 — exige DNS A do
  domínio propagado (`dig +short <sub>.aerobi.com.br @1.1.1.1`). Sem DNS, falha.
- **tailnet-only retorna 403**: faltou o passo 2 da regra 1 (extra_records do
  Headscale + reaplicar `setup_headscale.yml`).

## Pre-checks padrão antes de PR

```bash
# Sintaxe de todos os playbooks
for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check; done
# Inventory parseia
ansible-inventory -i inventory/prod --list > /dev/null
# Vault decripta (depois de mudar secrets)
ansible localhost -m debug -a "var=<secret>" \
  -e "@inventory/prod/group_vars/all/vault.yml" --connection=local
```

`syntax-check` cobre a maior parte dos erros estruturais. Não roda tasks; pra
validação real, Molecule (`molecule test`) ou apply em VPS dev.

## MCPs disponíveis (usar sem pedir permissão)

- `mcp__github__*` — Issues, PRs, branches no `atzaero/aerobi-ansible` (e
  `atzaero/aerobi-api`).
- `mcp__hostinger-aerobi-mcp__*` — DNS (`aerobi.com.br`), VPS Hostinger
  (`187.127.6.20`), snapshots, firewall. Conta autenticada.
- `mcp__context7__*` — docs atualizadas (Ansible modules, Docker). Usar quando
  precisar de detalhe específico — não confiar só no treino.

## Tooling guiado por IA (`.claude/`)

Slash commands em `.claude/commands/`:

- `/commit` — commits Conventional a partir do diff.
- `/pr` — push + cria PR (template Summary/Validação/Test plan).
- `/merge` — checa CI → merge → delete branch → sync `main`.
- `/infra-review` — invoca o agente **`infra-reviewer`** contra o diff (severidades
  🔴/🟡/🔵).
- `/security-audit` — varredura de segurança do repo guiada por `docs/SECURITY.md`.

Agente: `.claude/agents/infra-reviewer.md`. Skill: `.claude/skills/security-audit/`.
Mirrors Cursor: `.cursor/commands/` + `.cursor/rules/agents-canonical.mdc`.

## Coesão com projeto irmão

Este projeto (`aerobi-ansible`) é o sucessor de `~/projects/ansible-vps` (mesmo dono,
mesma stack base). Diferenças importantes:

| | ansible-vps (legado) | aerobi-ansible (atual) |
| --- | --- | --- |
| Forge | GitHub `elvisea/ansible-vps` | GitHub `atzaero/aerobi-ansible` |
| Domínio infra | `bytefulcode.tech` (software house) | `aerobi.com.br` (Registro.br) |
| VPN | Tailscale SaaS | Headscale self-hosted (este repo) |
| Postgres | Compartilhado | Compartilhado + sidecar tailnet (issue #7) |
| MinIO UID | 1000 (ou herdado) | 1001 explícito (gotcha Hostinger) |
| Edge nodes | Não havia | `aerodrome_edge` (Raspberry Pi + MediaMTX) |

Padrões compartilhados (mantenha simetria ao alterar):

- Vault per-value encryption + senha master em `~/.ansible-vault/<projeto>`.
- Roles de serviço com `defaults/main.yml`, `tasks/main.yml`, opcional `handlers/`,
  opcional `README.md`.
- Bind `127.0.0.1` + exposição via nginx_vhost com Certbot `--reinstall`.
- Validação fail-fast de credenciais default (`changeme`).
- Anti-padrão: nunca expor portas via Docker `-p` em IP público nem tailnet (NAT
  bypass do UFW).

Ao introduzir feature útil pra ambos: portar manualmente, não automatizar. Os repos
divergiram no propósito (legado tem multi-tenant, este tem produto único + edge).

## Documentação canônica

| Arquivo | O que cobre |
|---|---|
| `README.md` | Visão geral, roles, playbooks, sequências de uso |
| `docs/SECURITY.md` | **Threat model + checklist de segurança deste alvo** |
| `docs/BOOTSTRAP.md` | Runbook zero-to-prod: DNS → fresh-bootstrap → plataforma → vhosts |
| `docs/DOMINIOS.md` | Convenção de subdomínios + padrão tailnet-only + como adicionar serviço |
| `docs/PORTAS.md` | Alocação interna de portas + filtros UFW + tailnet-only pattern |
| `docs/VPN.md` | Mecanismo do Headscale + Magic DNS + extra_records |
| `docs/REGISTRO_BR.md` | DNS no Registro.br (pré-requisito do certbot) |
| `docs/INCIDENT_RESPONSE.md` | Triage de incidentes |
| `docs/COMO_USAR.md`, `docs/AMBIENTES.md`, `docs/MOLECULE.md` | Operação cotidiana |
| `docs/VARIAVEIS.md`, `docs/ROLES.md`, `docs/DATABASES.md` | Referência de vars, roles e DBs |
| `docs/TROUBLESHOOTING.md` | Problemas conhecidos + fixes |
| Header do `vault.yml` | Operações no vault (ver/add/update/rotate) |
