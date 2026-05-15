# aerobi-ansible

Automação Ansible da infraestrutura aerobi (VPS Hostinger Ubuntu 24.04 + Raspberry Pi edge nodes). Provisiona toda a stack a partir de uma VPS fresh — hardening base, plataforma de dados, mesh VPN (Headscale), serviços admin (Vaultwarden, MinIO, Uptime Kuma) e o app de produto (`aerobi-api`).

## O que este projeto entrega

- **Hardening base**: usuário `deploy` com sudo NOPASSWD, SSH key-only, UFW, Fail2Ban, `unattended-upgrades`, sysctl tunings.
- **Plataforma de dados**: PostgreSQL 17 (containerized, localhost only), provisionamento declarativo de DBs por app.
- **Mesh VPN**: Headscale self-hosted (control plane Tailscale-compatible), client Tailscale na VPS e edge nodes (Raspberry Pi de aeródromo).
- **Cofre de senhas**: Vaultwarden (backend Bitwarden) com `/admin` restrito à tailnet.
- **Object storage**: MinIO S3-compatible com buckets declarativos. Console admin tailnet-only.
- **Cache + filas**: Valkey (fork OSS do Redis) na rede docker.
- **Status + monitoring**: Uptime Kuma com Domain Name Expiry, HTTP/TCP/TLS monitors. Vhost tailnet-only.
- **Streaming RTSP→HLS**: MediaMTX no edge node de aeródromo, fan-out de câmeras IP.

## Roles

| Role | Responsabilidade | Documentação |
|---|---|---|
| `common` | Pacotes base, unattended-upgrades, sysctl hardening | [`docs/ROLES.md`](docs/ROLES.md) |
| `user` | Cria deploy user, authorized_keys, dir structure | |
| `ssh_hardening` | sshd config (no root, no password, MaxAuthTries) | |
| `firewall` | UFW (deny default, allow whitelist) | |
| `fail2ban` | Proteção SSH brute-force | |
| `nginx` | Web server | |
| `nginx_vhost` | Vhost reverse proxy + Certbot. Flags opcionais: `vhost_websocket_enabled`, `vhost_client_max_body_size`, `vhost_tailnet_only` | |
| `docker` + `docker_network` | Docker CE + rede `warpgate` | |
| `postgres` + `postgres_databases` | Postgres 17 + DBs/users por app | [`docs/DATABASES.md`](docs/DATABASES.md) |
| `headscale` | Control plane VPN self-hosted | [`docs/VPN.md`](docs/VPN.md) |
| `tailscale_client` | Conecta nó ao Headscale | |
| `vaultwarden` | Cofre Bitwarden com `/admin` tailnet-only | `roles/vaultwarden/README.md` |
| `valkey` | Fork OSS do Redis (cache/filas/sessões) | `roles/valkey/README.md` |
| `minio` | Object storage S3-compatible + buckets declarativos | `roles/minio/README.md` |
| `uptime_kuma` | Status + monitoring + Domain Name Expiry | `roles/uptime_kuma/README.md` |
| `sftpgo` | Servidor SFTP em Go com web admin (SQLite, tailnet-only) | `roles/sftpgo/README.md` |
| `sftpgo_tailnet_proxy` | Sidecar socat — expõe SFTP em `100.64.0.1:2022` via tailnet | |
| `mediamtx` | RTSP→HLS fan-out (câmeras IP, edge) | |
| `aerodrome_edge` | Raspberry Pi como subnet router Tailscale | |

## Playbooks

| Playbook | Orquestra | Quando usar |
|---|---|---|
| `setup_vps.yml` | common → user → ssh_hardening → firewall → fail2ban → nginx → docker → tailscale_client | Bootstrap zero-to-prod |
| `setup_database.yml` | docker_network → postgres | Provisionar Postgres |
| `setup_app_databases.yml` | postgres_databases | Criar DB+user por entrada de `postgres_apps` |
| `setup_headscale.yml` | docker_network → headscale → nginx_vhost | Sobe control plane VPN |
| `setup_vaultwarden.yml` | docker_network → vaultwarden + nginx_vhost (template próprio) | Cofre de senhas |
| `setup_valkey.yml` | docker_network → valkey | Cache/filas (sem vhost) |
| `setup_minio.yml` | docker_network → minio (+ buckets) | Object storage |
| `setup_uptime_kuma.yml` | docker_network → uptime_kuma | Monitoring (vhost via setup_app.yml) |
| `setup_sftpgo.yml` | docker_network → sftpgo → sftpgo_tailnet_proxy | Servidor SFTP (vhost via setup_app.yml, tailnet-only) |
| `setup_app.yml` | nginx_vhost (parametrizado) | Vhost + cert para qualquer app |
| `setup_aerodrome.yml` | aerodrome_edge (Raspi) | Edge subnet router + mediamtx |

## Ambientes

Dois inventários independentes:

| | dev | prod |
|---|---|---|
| Fail2Ban bantime | 5 min | 1 hora |
| MaxAuthTries SSH | 5 | 3 |
| Portas UFW abertas | 22, 80, 443, 5432, 5433, 5434, 9000, 9001 | 22, 80, 443 (+ UDP 41641 Tailscale) |
| Senhas | plaintext (dev) | Ansible Vault (`encrypt_string`) |

Inventário `prod` é o default (`ansible.cfg`); para dev usar `-i inventory/dev`.

## Fluxo de trabalho

```
Molecule (teste local) → dev (homologação) → prod (VPS principal)
```

## Uso rápido

### Testar localmente com Molecule

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install ansible molecule molecule-plugins[docker]
molecule test
```

### Aplicar em dev

```bash
ansible-playbook -i inventory/dev playbooks/setup_vps.yml
```

### Aplicar em prod

Sequência completa em [`docs/BOOTSTRAP.md`](docs/BOOTSTRAP.md). Resumo:

```bash
# 0. DNS no Registro.br para todos os subdomínios → 187.127.6.20
# 1. Bootstrap base
ansible-playbook playbooks/setup_vps.yml
# 2. Plataforma de dados
ansible-playbook playbooks/setup_database.yml
ansible-playbook playbooks/setup_app_databases.yml
# 3. Mesh VPN
ansible-playbook playbooks/setup_headscale.yml
# 4-8. Serviços
ansible-playbook playbooks/setup_vaultwarden.yml
ansible-playbook playbooks/setup_valkey.yml
ansible-playbook playbooks/setup_minio.yml
ansible-playbook playbooks/setup_uptime_kuma.yml
ansible-playbook playbooks/setup_sftpgo.yml
# 9. Vhosts admin-only / públicos
ansible-playbook playbooks/setup_app.yml -e "app_name=... app_domain=... app_port=..."
```

## Documentação

### Operacional (runbooks)

- [Como usar passo a passo](docs/COMO_USAR.md)
- [Bootstrap zero-to-prod](docs/BOOTSTRAP.md) — runbook completo (recriar VPS)
- [DNS no Registro.br](docs/REGISTRO_BR.md) — pré-requisito para certbot
- [Convenção de domínios](docs/DOMINIOS.md) — subdomínios e exposição
- [Portas e firewall](docs/PORTAS.md) — alocação interna + tailnet-only pattern
- [Incident response](docs/INCIDENT_RESPONSE.md) — checklist quando algo está estranho

### Referência

- [Ambientes dev e prod](docs/AMBIENTES.md)
- [Variáveis disponíveis](docs/VARIAVEIS.md)
- [O que cada role faz](docs/ROLES.md)
- [Bancos de dados](docs/DATABASES.md)
- [DBeaver via SSH tunnel](docs/DBEAVER.md)
- [VPN Headscale + Tailscale](docs/VPN.md)
- [Deploy de app via GitHub Actions](docs/DEPLOY_APP.md)

### Tooling

- [Testes com Molecule](docs/MOLECULE.md)
- [GitHub Actions CI/CD](docs/GITHUB_ACTIONS.md)
- [Problemas comuns](docs/TROUBLESHOOTING.md)
