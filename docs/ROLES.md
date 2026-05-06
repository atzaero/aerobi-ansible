# O que cada role faz

Uma **role** no Ansible é uma unidade reutilizável de configuração. Cada role tem uma responsabilidade única e pode ser executada de forma independente via tags.

---

## common

**Tag:** `common`, `base`

**O que faz:**
- Atualiza o cache do apt e todos os pacotes do sistema
- Instala pacotes essenciais: `git`, `curl`, `wget`, `unzip`, `ca-certificates`, `gnupg`
- Instala e ativa o `unattended-upgrades` (atualizações automáticas de segurança)
- Remove pacotes desnecessários (`autoremove`)

**Por que é importante:**
Garante que o sistema está atualizado antes de qualquer outra configuração, evitando vulnerabilidades conhecidas.

---

## user

**Tag:** `user`

**O que faz:**
- Cria o usuário definido em `deploy_user` (padrão: `deploy`)
- Adiciona o usuário ao grupo `sudo`
- Cria o diretório `.ssh` com permissões corretas
- Adiciona sua chave pública SSH em `authorized_keys`
- Cria a estrutura de diretórios: `apps/`, `databases/`, `scripts/`, `backups/`
- Configura sudo sem senha para o usuário deploy

**Por que é importante:**
Nunca se deve trabalhar como root no dia a dia. Esta role cria um usuário dedicado para deploy com acesso controlado.

---

## ssh_hardening

**Tag:** `ssh`, `security`

**O que faz:**
- Desabilita login root via SSH (`PermitRootLogin no`)
- Desabilita autenticação por senha (`PasswordAuthentication no`)
- Desabilita `X11Forwarding`
- Desabilita `PermitEmptyPasswords`
- Desabilita `AllowTcpForwarding`
- Limita tentativas de autenticação (`MaxAuthTries 3`)
- Define permissões corretas em `/etc/passwd` e `/etc/shadow`

**Por que é importante:**
São as configurações mínimas para proteger o SSH contra ataques automatizados que tentam adivinhar senhas de root.

**Atenção:** após esta role rodar, só é possível conectar via chave SSH. Certifique-se de ter adicionado sua chave antes.

---

## firewall

**Tag:** `firewall`, `security`

**O que faz:**
- Instala o UFW (Uncomplicated Firewall)
- Bloqueia todo tráfego de entrada por padrão
- Permite todo tráfego de saída
- Libera as portas definidas em `ufw_allowed_ports` (padrão: 22, 80, 443)
- Ativa o firewall

**Por que é importante:**
Reduz a superfície de ataque expondo apenas as portas necessárias para o servidor funcionar.

---

## fail2ban

**Tag:** `fail2ban`, `security`

**O que faz:**
- Instala o Fail2Ban
- Cria o arquivo `/etc/fail2ban/jail.local` a partir de um template com as variáveis configuradas
- Monitora tentativas de login SSH
- Bane automaticamente IPs que excedem o limite de tentativas
- Garante que o serviço inicia com o sistema

**Por que é importante:**
Complementa o firewall bloqueando dinamicamente IPs que tentam ataques de força bruta. Essencial para qualquer servidor exposto à internet.

**Como desbanir um IP manualmente:**
```bash
fail2ban-client unban SEU_IP
```

---

## nginx

**Tag:** `nginx`

**O que faz:**
- Instala o Nginx
- Garante que está ativo e inicia com o sistema
- Cria uma página padrão em `/var/www/html/index.html`

**Nota:** esta role apenas instala o Nginx. A configuração de sites (virtual hosts, SSL, proxy reverso) é feita manualmente ou por roles específicas de cada aplicação.

---

## docker

**Tag:** `docker`

**O que faz:**
- Remove versões antigas do Docker (docker.io, podman-docker, etc.)
- Adiciona o repositório oficial do Docker com chave GPG verificada
- Instala: `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`
- Garante que Docker e containerd iniciam com o sistema
- Adiciona o usuário `deploy` ao grupo `docker` (permite usar Docker sem sudo)

**Por que instalar do repositório oficial:**
O Docker disponível via `apt install docker.io` é uma versão mais antiga mantida pelo Ubuntu. O repositório oficial sempre tem a versão mais recente e estável.

**Verificar instalação:**
```bash
docker --version
docker compose version
docker run hello-world
```

---

## headscale

**Tag:** `headscale`, `vpn`

**O que faz:**
- Sobe o Headscale como container (`headscale/headscale`) com config gerada do template
- Reusa o PostgreSQL existente como banco (database `headscale`)
- Cria virtual host Nginx em `headscale.aerobi.com.br` com SSL via Let's Encrypt
- Renderiza ACL em `acl.json` com tags `tag:vps`, `tag:airfield`, `tag:dev`
- Garante que o user `aerobi` existe na tailnet

**Por que importa:**
Control plane self-hosted compatível com clientes Tailscale. Permite mesh VPN entre VPS, dev, celular e (futuramente) servidores de aeródromo, sem cap de devices nem dependência SaaS.

**Provisionamento manual após primeiro deploy:**
```bash
# Gerar pre-auth key reusable da VPS
docker exec headscale headscale preauthkeys create \
  --user aerobi --reusable --expiration 90d --tags tag:vps

# Salvar a key no vault como vault_headscale_authkey_vps
ansible-vault encrypt_string --vault-id default@~/.ansible-vault/prod \
  --encrypt-vault-id default --stdin-name 'vault_headscale_authkey_vps'
```

---

## tailscale_client

**Tag:** `tailscale`, `vpn`

**O que faz:**
- Adiciona o repo APT oficial do Tailscale e instala o pacote
- Habilita `tailscaled.service`
- Conecta ao Headscale via `tailscale up --login-server=https://headscale.aerobi.com.br --authkey=…`

**Idempotência:**
- Pula `tailscale up` se o nó já está autenticado e o backend está `Running`
- Se `vault_headscale_authkey_vps` está vazio (primeiro deploy do Headscale, antes de gerar key), a role inteira é pulada via `meta: end_play`

**Por que importa:**
É o que efetivamente coloca a VPS na tailnet. Sem ele, o Headscale roda mas não tem clientes.
