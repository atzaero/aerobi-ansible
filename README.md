# ansible-vps

Projeto de automação de infraestrutura com Ansible para configuração de servidores VPS (Hostinger/Ubuntu 24.04).

## O que este projeto faz

Com um único comando, configura uma VPS do zero:

- Cria usuário com sudo e estrutura de diretórios
- Hardening de segurança do SSH
- Firewall UFW
- Fail2Ban (proteção contra brute-force)
- Git, Nginx e Docker CE
- Atualizações automáticas de segurança

## Ambientes

O projeto suporta dois ambientes com configurações independentes:

| | dev | prod |
|---|---|---|
| Fail2Ban bantime | 5 min | 1 hora |
| MaxAuthTries | 5 | 3 |
| Portas abertas | 22, 80, 443, 5432, 9000, 9001 | 22, 80, 443 |

## Fluxo de trabalho

```
Molecule (teste local) --> dev (VPS de homologação) --> prod (VPS principal)
```

## Estrutura do projeto

```
ansible-vps/
├── inventory/
│   ├── dev/
│   │   ├── hosts.yml           # IP da VPS de dev
│   │   └── group_vars/
│   │       └── all.yml         # variáveis do ambiente dev
│   └── prod/
│       ├── hosts.yml           # IP da VPS de prod
│       └── group_vars/
│           └── all.yml         # variáveis do ambiente prod
├── molecule/
│   └── default/
│       ├── molecule.yml        # configuração do ambiente de teste
│       ├── converge.yml        # playbook executado no container
│       └── verify.yml          # testes de verificação
├── roles/
│   ├── common/                 # pacotes base e atualizações
│   ├── user/                   # criação de usuário e diretórios
│   ├── ssh_hardening/          # segurança do SSH
│   ├── firewall/               # firewall UFW
│   ├── fail2ban/               # proteção contra brute-force
│   ├── nginx/                  # servidor web Nginx
│   └── docker/                 # Docker CE
├── playbooks/
│   ├── setup_vps.yml           # configuração completa da VPS
│   └── setup_docker.yml        # instala apenas o Docker
└── docs/
    ├── COMO_USAR.md
    ├── AMBIENTES.md
    ├── MOLECULE.md
    ├── VARIAVEIS.md
    ├── ROLES.md
    └── TROUBLESHOOTING.md
```

## Uso rápido

### Testar localmente com Molecule

```bash
# Instalar dependências
python3 -m venv .venv
source .venv/bin/activate
pip install ansible molecule molecule-plugins[docker]

# Rodar testes
molecule test
```

### Aplicar em dev

```bash
ansible-playbook -i inventory/dev playbooks/setup_vps.yml
```

### Aplicar em prod

```bash
ansible-playbook -i inventory/prod playbooks/setup_vps.yml
```

## Documentação completa

- [Como usar passo a passo](docs/COMO_USAR.md)
- [Ambientes dev e prod](docs/AMBIENTES.md)
- [Testes com Molecule](docs/MOLECULE.md)
- [Variáveis disponíveis](docs/VARIAVEIS.md)
- [O que cada role faz](docs/ROLES.md)
- [Problemas comuns](docs/TROUBLESHOOTING.md)
