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
