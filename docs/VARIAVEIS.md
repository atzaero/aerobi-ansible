# Variáveis do projeto

Todas as variáveis ficam em `group_vars/all.yml`. Abaixo a documentação completa de cada uma.

---

## Usuário de deploy

| Variável | Padrão | Descrição |
|---|---|---|
| `deploy_user` | `deploy` | Nome do usuário criado na VPS para gerenciar apps |
| `deploy_email` | — | Email associado à chave SSH |
| `deploy_ssh_public_key` | — | Chave pública SSH da sua máquina local |

**Como obter a chave pública:**
```bash
cat ~/.ssh/id_ed25519.pub
```

**Exemplo:**
```yaml
deploy_user: deploy
deploy_email: elvis@email.com
deploy_ssh_public_key: "ssh-ed25519 AAAAC3Nz... elvis@email.com"
```

---

## SSH

| Variável | Padrão | Descrição |
|---|---|---|
| `ssh_port` | `22` | Porta do SSH |
| `ssh_max_auth_tries` | `3` | Máximo de tentativas de autenticação por conexão |
| `ssh_permit_root_login` | `no` | Permite login como root via SSH? |
| `ssh_password_authentication` | `no` | Permite autenticação por senha? |

**Atenção:** após o playbook rodar, o login por senha fica desabilitado. Certifique-se de que sua chave SSH foi adicionada antes de executar.

---

## Firewall (UFW)

| Variável | Padrão | Descrição |
|---|---|---|
| `ufw_allowed_ports` | `[22, 80, 443]` | Lista de portas TCP liberadas no firewall |

**Exemplo com porta extra (ex: MinIO):**
```yaml
ufw_allowed_ports:
  - 22
  - 80
  - 443
  - 9000   # MinIO API
  - 9001   # MinIO Console
```

---

## Fail2Ban

| Variável | Padrão | Descrição |
|---|---|---|
| `fail2ban_bantime` | `3600` | Tempo de ban em segundos (3600 = 1 hora) |
| `fail2ban_maxretry` | `3` | Tentativas antes de banir o IP |
| `fail2ban_findtime` | `600` | Janela de tempo para contar tentativas (segundos) |

**Exemplo mais restritivo:**
```yaml
fail2ban_bantime: 86400    # 24 horas de ban
fail2ban_maxretry: 3
fail2ban_findtime: 300     # 5 minutos
```

---

## Diretórios do usuário deploy

| Variável | Padrão | Descrição |
|---|---|---|
| `deploy_directories` | `[apps, databases, scripts, backups]` | Pastas criadas no home do usuário |

**Exemplo com pasta extra:**
```yaml
deploy_directories:
  - apps
  - databases
  - scripts
  - backups
  - logs
```

Resultado: cria `/home/deploy/apps`, `/home/deploy/databases`, etc.
