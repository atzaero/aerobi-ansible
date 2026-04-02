# Ambientes dev e prod

## Conceito

O projeto separa as configurações em dois ambientes para que você possa:

1. **Testar** mudanças em dev sem afetar produção
2. **Validar** que tudo funciona antes de aplicar em prod
3. **Configurar** cada ambiente de forma independente (portas, restrições, etc.)

## Fluxo recomendado

```
Molecule --> dev --> prod
(local)    (VPS teste)  (VPS principal)
```

1. Você faz uma mudança no projeto (ex: adiciona uma nova role)
2. Roda `molecule test` para testar em container local
3. Se passar, aplica em dev: `ansible-playbook -i inventory/dev playbooks/setup_vps.yml`
4. Valida que está funcionando na VPS de dev
5. Aplica em prod: `ansible-playbook -i inventory/prod playbooks/setup_vps.yml`

---

## Diferenças entre os ambientes

### Segurança

| Configuração | dev | prod |
|---|---|---|
| `fail2ban_bantime` | 5 min | 1 hora |
| `fail2ban_maxretry` | 5 tentativas | 3 tentativas |
| `ssh_max_auth_tries` | 5 | 3 |

**Por quê:** em dev você vai testar conexões, rodar scripts e talvez errar a chave algumas vezes. Em prod, qualquer IP que errar 3 vezes é banido por 1 hora.

### Firewall

| Porta | dev | prod | Serviço |
|---|---|---|---|
| 22 | ✅ | ✅ | SSH |
| 80 | ✅ | ✅ | HTTP |
| 443 | ✅ | ✅ | HTTPS |
| 5432 | ✅ | ❌ | PostgreSQL |
| 5433 | ✅ | ❌ | PostgreSQL (viki) |
| 5434 | ✅ | ❌ | PostgreSQL (evolution) |
| 9000 | ✅ | ❌ | MinIO API |
| 9001 | ✅ | ❌ | MinIO Console |

**Por quê:** em dev é útil acessar banco e MinIO diretamente pela porta. Em prod, tudo passa pelo Nginx (proxy reverso) — nenhuma porta de serviço fica exposta.

---

## Estrutura de arquivos

Cada ambiente tem seu próprio inventário e variáveis:

```
inventory/
├── dev/
│   ├── hosts.yml           # IP da VPS de dev
│   └── group_vars/
│       └── all.yml         # variáveis específicas do dev
└── prod/
    ├── hosts.yml           # IP da VPS de prod
    └── group_vars/
        └── all.yml         # variáveis específicas do prod
```

O Ansible carrega automaticamente as variáveis do `group_vars/all.yml` do inventário que você passar no comando.

---

## Como configurar um novo ambiente

### 1. Copiar a estrutura

```bash
cp -r inventory/dev inventory/staging
```

### 2. Editar o hosts.yml

```yaml
# inventory/staging/hosts.yml
all:
  hosts:
    vps-staging:
      ansible_host: IP_DO_STAGING
      ansible_user: root
      ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

### 3. Ajustar as variáveis

Edite `inventory/staging/group_vars/all.yml` com as configurações desejadas.

### 4. Rodar o playbook

```bash
ansible-playbook -i inventory/staging playbooks/setup_vps.yml
```

---

## Variáveis que diferem por ambiente

Para adicionar uma variável que tem valor diferente por ambiente, basta colocá-la no `group_vars/all.yml` de cada ambiente com valores diferentes. O Ansible sempre usa o valor do inventário especificado no comando.
