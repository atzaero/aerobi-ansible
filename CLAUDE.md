# CLAUDE.md

Convenções do projeto aerobi-ansible. Carregado automaticamente em toda sessão do Claude Code dentro deste repo. Mantenha curto: foca em regras que não dá pra inferir do código.

## Stack mental rápida

VPS Hostinger Ubuntu 24.04 (`vps-prod`, `187.127.6.20`, tailnet `100.64.0.1`). Stack composta por containers Docker numa rede compartilhada `warpgate`, exposta por nginx reverse proxy com TLS via Let's Encrypt. Serviços admin ficam atrás de tailnet — clientes acessam via Headscale self-hosted.

## Regras estritas

### 1. Toda nova role/serviço com `vhost_tailnet_only=true` precisa de DUAS coisas

1. Vhost criado via `setup_app.yml -e "... vhost_tailnet_only=true"`
2. Entrada em `headscale_extra_dns_records` (em `roles/headscale/defaults/main.yml`) apontando o subdomínio para `100.64.0.1`, **mais** reaplicar `playbooks/setup_headscale.yml`

Sem o passo 2, o cliente resolve o domínio para o IP público, tráfego sai pela internet, nginx vê o IP público em `$remote_addr` e retorna **403 mesmo com tailscale up**. Os dois passos são complementares — o vhost filtra, o extra DNS record força o tráfego do cliente a entrar pela tailnet.

Mecanismo detalhado: [`docs/VPN.md → Magic DNS e extra_records`](docs/VPN.md#magic-dns-e-extra_records).
Procedimento operacional: [`docs/DOMINIOS.md → Adicionar um serviço de infra novo`](docs/DOMINIOS.md#adicionar-um-serviço-de-infra-novo).

### 2. Container Docker: bind sempre em `127.0.0.1`, nunca em `0.0.0.0`

Exposição externa é responsabilidade do nginx (com TLS) ou do socat sidecar (para tailnet). Bind em `0.0.0.0` vaza o serviço para a internet pública mesmo com UFW deny default — o Docker insere regras `iptables -t nat` que são avaliadas **antes** do UFW (issue #7).

### 3. Serviços expostos via tailnet usam socat sidecar com `network_mode: host`

NÃO usar `-p 100.64.0.1:porta:porta` no `docker_container` — mesmo motivo da regra 2 (Docker NAT bypass). Padrão estabelecido em `roles/postgres_tailnet_proxy/` e `roles/sftpgo_tailnet_proxy/`: container `alpine/socat` separado, `network_mode: host`, escutando direto na interface `tailscale0`.

### 4. Imagens distroless: usar healthcheck nativo

Várias imagens em uso (drakkan/sftpgo, vaultwarden/server) são distroless — não têm `curl`, `wget`, `nc`. Antes de definir `healthcheck.test` com utilitários shell, verificar:

```bash
docker exec <container> sh -c "command -v curl wget nc"
```

Se nada disponível, procurar healthcheck próprio do binário (ex: `sftpgo ping`).

### 5. Secrets sempre em vault, validação fail-fast nas roles

Pattern em `roles/*/defaults/main.yml`: senha default = `changeme`. Pattern em `roles/*/tasks/main.yml`:

```yaml
- name: Validar senha (não pode estar em 'changeme')
  fail:
    msg: "Adicione vault_<service>_password ao vault antes de aplicar"
  when: <service>_password in ['changeme', '', None]
```

Como adicionar secret novo está documentado no header do `inventory/prod/group_vars/all/vault.yml`.

### 6. Comportamento sobre merges e operações destrutivas

- Branches: `tipo/descricao-kebab` (ex: `feat/sftpgo`, `fix/headscale-extra-record-sftpgo`).
- Commits no padrão Conventional Commits em PT-BR (`feat(escopo): descrição`).
- Base branch: `main` (não `develop`).
- Fluxo de merge via `gh pr merge --merge --delete-branch` (sem squash, sem rebase, salvo pedido explícito).
- **Sempre rodar playbooks em prod DEPOIS do merge**, não antes — garante que `main` reflete o estado real da VPS.

### 7. Sempre verificar pré-condições antes de aplicar playbook

Para um serviço novo com vhost:

- DNS no Registro.br propagado (`dig +short <sub>.aerobi.com.br @1.1.1.1`)
- Senha do vault adicionada
- Se for tailnet-only: extra_records do Headscale **antes** ou **junto** do setup_app.yml (sem isso, vhost retorna 403)
- SSH para `deploy@187.127.6.20` funcional

## Vault (per-value encryption, não file-level)

Cada secret é um bloco `!vault | $ANSIBLE_VAULT;1.1;AES256` individual encriptado via `ansible-vault encrypt_string`. **Não** é file-level. Consequências práticas:

- **`ansible-vault view <arquivo>` NÃO funciona** — falha com "Input is not vault encrypted data". Use `ansible localhost -m debug -a "var=<nome>" -e "@inventory/prod/group_vars/all/vault.yml" --connection=local` para decriptar um secret.
- **`ansible-vault rekey` NÃO funciona** — só funcionaria pra file-level. Pra rotacionar a master, gerar nova senha + regerar cada bloco individual + substituir no arquivo.
- Senha master em `~/.ansible-vault/aerobi-prod`. Não commitada (fora do working tree). `ansible.cfg` aponta via `vault_password_file`.

Header do `inventory/prod/group_vars/all/vault.yml` tem o guia completo (ver/adicionar/atualizar/rotacionar secrets, copiar pro clipboard, etc).

## Gotchas conhecidos

- **NOPASSWD sudoers**: usuário `deploy` precisa de `NOPASSWD:ALL` em `/etc/sudoers.d/deploy`. Allowlist restritiva quebra módulos Ansible que rodam `python3` como root. Ver `roles/user/tasks/main.yml`.
- **Certbot `--reinstall`**: já configurado em `roles/nginx_vhost/tasks/main.yml`. Sem essa flag, em VPS fresh às vezes o certbot emite cert mas o vhost não recebe `listen 443 ssl;` (race condition). Não remover.
- **MinIO uid:gid = 1001**: container roda como dono do volume montado. Default 1000:1000; em VPS Hostinger o `deploy` é 1001:1001. Definido em `minio_container_uid/gid` no inventory. Mudar = arquivos em `/data` com owner errado.
- **Fresh-bootstrap inventory**: VPS recém-formatada não tem `deploy` ainda. Editar `inventory/prod/hosts.yml` temporariamente para `ansible_user: root` + comentar `ansible_become`. Após `setup_vps.yml`, reverter. Runbook detalhado em `docs/BOOTSTRAP.md` Passos 1.3–1.5.
- **DNS antes de TLS**: `setup_app.yml` roda certbot HTTP-01 — exige DNS A do domínio apontando pro IP da VPS, propagado (`dig +short <sub>.aerobi.com.br @1.1.1.1`). Sem DNS, falha.

## Pre-checks padrão antes de PR

```bash
# Sintaxe de todos os playbooks
for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check; done

# Inventory parseia OK
ansible-inventory -i inventory/prod --list > /dev/null

# Vault decripta (depois de mudar secrets)
ansible localhost -m debug -a "var=<nome_secret>" \
  -e "@inventory/prod/group_vars/all/vault.yml" --connection=local
```

`syntax-check` cobre maior parte dos erros estruturais (YAML inválido, módulo inexistente, vars não resolvíveis). Não roda tasks; pra validação real, Molecule (`molecule test`) ou apply em VPS dev.

## MCPs disponíveis (usar sem pedir permissão)

- `mcp__github__*` — Issues, PRs, branches no repo `atzaero/aerobi-ansible` e em apps relacionados (`atzaero/aerobi-api`).
- `mcp__hostinger-aerobi-mcp__*` — DNS (`aerobi.com.br`), VPS Hostinger (`187.127.6.20`), snapshots, firewall. Conta já autenticada.
- `mcp__context7__*` — docs atualizadas (Ansible modules, Docker, libs específicas). Usar quando precisar de detalhe — não confiar só no treino.

## Notas Claude-específicas

- **Plan mode**: acionar antes de mudanças estruturais grandes (nova role complexa, refactor amplo, adição de serviço). Skip pra edits triviais (typo, ajuste de var).
- **Agent Explore (`subagent_type=Explore`)**: usar pra pesquisas amplas no codebase (3+ queries) — protege o contexto principal. Pra grep/find pontual de symbol ou file, use Bash direto.
- **Agent `isolation: worktree`**: precisa que a session Claude tenha iniciado dentro do repo. Confirmar com `git rev-parse --show-toplevel`.
- **Tools deferidos (MCPs, ferramentas extras)**: usar `ToolSearch` com `select:<nome>` quando precisar de algo não carregado por padrão (ex: `WebFetch`, `TaskCreate`, `mcp__github__*`).
- **Comandos pesados** (build, test suite, ansible apply em prod): rodar com `run_in_background: true` se demorar > 1 min.

## Coesão com projeto irmão

Este projeto (`aerobi-ansible`) é o sucessor de `~/projects/ansible-vps` (mesmo dono, mesma stack base). Diferenças importantes:

| | ansible-vps (legado) | aerobi-ansible (atual) |
| --- | --- | --- |
| Domínio infra | `bytefulcode.tech` (software house) | `aerobi.com.br` |
| VPN | Tailscale SaaS | Headscale self-hosted (este repo) |
| Postgres | Compartilhado | Compartilhado + sidecar tailnet (issue #7) |
| MinIO UID | 1000 (ou herdado) | 1001 explícito (gotcha Hostinger) |
| Edge nodes | Não havia | `aerodrome_edge` (Raspberry Pi + MediaMTX) |

Padrões compartilhados (mantenha simetria ao alterar):

- Vault per-value encryption + senha master em `~/.ansible-vault/<projeto>`
- Roles de serviço com `defaults/main.yml`, `tasks/main.yml`, opcional `handlers/`, opcional `README.md`
- Bind `127.0.0.1` + exposição via nginx_vhost com Certbot `--reinstall`
- Validação fail-fast de credenciais default (`changeme`)
- Anti-padrão: nunca expor portas via Docker `-p` em IP público nem tailnet (Docker NAT bypass do UFW)

Ao introduzir feature útil pra ambos: portar manualmente, não automatizar. Os repos divergiram no propósito (legado tem multi-tenant, este tem produto único + edge).

## Documentação operacional canônica

| Tópico | Arquivo |
| --- | --- |
| Onboarding de dev/contributor | [`README.md`](README.md) |
| Bootstrap zero-to-prod da VPS | [`docs/BOOTSTRAP.md`](docs/BOOTSTRAP.md) |
| Convenção de subdomínios e padrão tailnet-only | [`docs/DOMINIOS.md`](docs/DOMINIOS.md) |
| Mapa de portas + filtros UFW | [`docs/PORTAS.md`](docs/PORTAS.md) |
| Mecanismo do Headscale + Magic DNS | [`docs/VPN.md`](docs/VPN.md) |
| Detalhe de cada role | [`docs/ROLES.md`](docs/ROLES.md) |
| Variáveis do projeto | [`docs/VARIAVEIS.md`](docs/VARIAVEIS.md) |
| Vault e secrets | header do [`inventory/prod/group_vars/all/vault.yml`](inventory/prod/group_vars/all/vault.yml) |

Roles com README dedicado: `roles/sftpgo/`, `roles/uptime_kuma/`, `roles/valkey/`, `roles/minio/`. Vaultwarden tem doc nos comentários inline da role.
