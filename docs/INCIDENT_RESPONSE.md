# Incident Response — Checklist

Playbook para quando algo estranho acontecer na VPS aerobi (site retornando 403 de servidor desconhecido, containers unhealthy, logins não reconhecidos, tráfego anômalo, processos que não colocou lá, DNS apontando para lugar errado).

## 1. Triagem rápida — é comprometimento ou bug?

Antes de entrar em pânico, descarte o mundano **nesta ordem**:

- **Domínio expirou?** (SEMPRE checar primeiro — mais comum que compromise)

  ```bash
  whois aerobi.com.br | grep -iE "(expir|status|registrar)" | head -5
  ```

  Procure por `Status: redemption|pendingDelete|clientHold`, data de expiração no passado, ou mensagens "pending delete". Domínio expirado volta para servidor de parking do Registro.br, que retorna página de renovação. Parece compromise mas é só renovação esquecida.

  > **Lição transferida** (incidente histórico em outro projeto, 2026-04-24): um domínio pessoal expirou e gerou falso alarme — 40 min de investigação até descobrir que era só renovação. Por isso este passo é o primeiro. Configurar **Domain Name Expiry** monitor no Uptime Kuma para `aerobi.com.br` é defesa preventiva.

- **DNS apontando para lugar errado (sem expiração)?** — `dig +short aerobi.com.br` (e subdomínios) contra múltiplos resolvers (`8.8.8.8`, `1.1.1.1`, `9.9.9.9`). Compare com o que está cadastrado no painel Registro.br.
- **Container unhealthy mas servindo?** — `docker inspect <name> --format='{{.State.Health.Status}}'` vs `curl localhost:<porta>/`. Se app responde 200 mas healthcheck falha, provavelmente healthcheck quebrado (porta errada, URL que não existe).
- **403 "estranho" do navegador** — verifique o header `Server:` via `curl -sI <url> | grep -i server`. `Server: nginx` é seu; outro pode ser CDN/parking/outro provider onde DNS aponta.
- **403 em endpoint admin (s3-console, status, /admin do vaultwarden)** — você está sem tailscale. Esses endpoints são tailnet-only por design. `tailscale up` resolve.
- **Processo suspeito** — pode ser parte normal do sistema (systemd, docker, containers). `ps auxf` mostra a árvore; busque por processo pai.

Se os 6 acima não explicam, escalar para procedimento completo.

## 2. Isolamento imediato (não hesite)

Se há indicação forte de comprometimento:

### 2.1. Tirar da internet (sem desligar)

```bash
# Via console web do provedor (Hostinger painel → Firewall):
#   Permitir apenas o seu IP residencial em 22, bloquear 0.0.0.0/0 no resto.
# Ou via UFW na própria VPS (se ainda dá pra logar):
sudo ufw default deny incoming
sudo ufw allow from <SEU_IP_RESIDENCIAL> to any port 22
sudo ufw --force enable
```

**Não `shutdown`/`poweroff`.** RAM contém estado volátil (conexões, processos, possíveis IoCs) que você perde ao desligar. Manter up + offline preserva forense.

### 2.2. Snapshot antes de qualquer ação

Pelo painel Hostinger → Snapshots tira um snapshot **imediatamente**. Preserva disco no estado atual para análise forense posterior, mesmo se você fizer algo destrutivo na VPS.

## 3. Coleta de evidência (read-only)

Se vai formatar de qualquer jeito (passo 5 em diante), ainda vale coletar antes de apagar — útil para identificar vetor e evitar reincidir o erro.

### 3.1. Artefatos críticos

```bash
# Via SSH antes de derrubar a rede, OU via console web post-isolamento:

# Logs de auth (SSH, sudo, cron)
sudo tar czf /tmp/evidence-auth.tgz /var/log/auth.log* /var/log/sudo-io/ 2>/dev/null

# History de todos os usuários
for u in /root /home/*; do
  sudo cp -v "$u/.bash_history" "/tmp/evidence-hist-$(basename $u).txt" 2>/dev/null
done

# Processos em execução + conexões
ps auxf > /tmp/evidence-ps.txt
ss -tulnp > /tmp/evidence-ss.txt
sudo netstat -nap > /tmp/evidence-netstat.txt 2>/dev/null

# Crontabs de root e users
sudo crontab -l > /tmp/evidence-cron-root.txt
for u in $(ls /home/); do sudo crontab -u "$u" -l > "/tmp/evidence-cron-$u.txt" 2>/dev/null; done
ls -la /etc/cron.* /etc/cron.d/ > /tmp/evidence-cron-etc.txt

# Arquivos modificados recentemente (últimos 7 dias)
sudo find / -xdev -type f -mtime -7 -not -path '/proc/*' -not -path '/sys/*' -not -path '/var/log/*' 2>/dev/null > /tmp/evidence-modified.txt

# systemd services customizados (fonte comum de persistência)
ls -la /etc/systemd/system/ > /tmp/evidence-systemd.txt
sudo systemctl list-units --type=service --state=running > /tmp/evidence-services.txt

# SSH authorized_keys (backdoor comum)
for u in /root /home/*; do
  sudo cat "$u/.ssh/authorized_keys" 2>/dev/null | sed "s|^|$(basename $u): |" >> /tmp/evidence-ssh-keys.txt
done

# Docker containers + imagens (pode ter container malicioso)
docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Command}}" > /tmp/evidence-docker-ps.txt
docker images > /tmp/evidence-docker-images.txt

# Logs do nginx (analysis de hits suspeitos)
sudo tar czf /tmp/evidence-nginx.tgz /var/log/nginx/ 2>/dev/null

# firewall state atual
sudo ufw status verbose > /tmp/evidence-ufw.txt
sudo iptables -L -n -v > /tmp/evidence-iptables.txt

# Package-level changes (pacotes instalados/removidos recentemente)
sudo grep -E "install |remove " /var/log/dpkg.log* > /tmp/evidence-dpkg.txt 2>/dev/null

# Tailscale state (alguém adicionou node não autorizado?)
tailscale status > /tmp/evidence-tailscale.txt
docker exec headscale headscale nodes list > /tmp/evidence-headscale-nodes.txt 2>/dev/null

# Sumário
tar czf /tmp/evidence-$(hostname)-$(date +%Y%m%d-%H%M).tgz /tmp/evidence-*.txt /tmp/evidence-*.tgz
```

### 3.2. Enviar para fora da VPS comprometida

```bash
# Do seu laptop:
scp deploy@187.127.6.20:/tmp/evidence-*.tgz ~/incidents/
```

**Não** confie nos logs que estão na VPS comprometida — atacante competente apaga. Mas sempre pegue — nem todo atacante é competente.

## 4. Análise rápida (pattern de IoC)

```bash
# Binários SUID suspeitos (escalação privilégio)
find / -xdev -type f -perm -4000 2>/dev/null | diff - <(cat <<'EOF'
/usr/bin/newgrp
/usr/bin/su
/usr/bin/sudo
/usr/bin/passwd
/usr/bin/chfn
/usr/bin/chsh
/usr/bin/gpasswd
/usr/bin/mount
/usr/bin/umount
/usr/lib/openssh/ssh-keysign
EOF
)
# Linhas com `< ` indicam SUIDs a mais — possível backdoor.

# Users que não deveriam estar lá
cat /etc/passwd | grep -v -E '^(root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody|_apt|systemd|messagebus|sshd|deploy|tss|uuidd|tcpdump|landscape|pollinate|fwupd-refresh|usbmux|sssd|_rpc|dnsmasq|dhcpd):'

# Conexões outbound persistentes (C2 ou exfil)
ss -tnp | awk 'NR>1 {print $5}' | sort -u | grep -vE '^(127\.|10\.|192\.168\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.|100\.6[4-9]\.|100\.[7-9][0-9]\.|100\.1[0-1][0-9]\.|100\.12[0-7]\.)'
# Os ranges 100.64-127 são o CGNAT da tailnet — tráfego ali é ok.

# Processos rodando de locais incomuns
ls -la /proc/*/exe 2>/dev/null | grep -vE 'usr/(s)?bin|usr/lib|usr/sbin|snap'

# Nodes inesperados na tailnet (alguém adicionou laptop não autorizado?)
docker exec headscale headscale nodes list
```

## 5. Rebuild vs Limpeza

**Regra**: se há indicação forte de root compromise (modificação em `/etc`, `/usr`, usuário novo, serviço systemd não reconhecido), **rebuild from scratch** é o único caminho confiável. Tentar "limpar" um sistema comprometido raramente remove tudo — rootkits se escondem.

**Se optou por rebuild** (o caminho recomendado):

1. **Tire último snapshot** (para análise offline depois).
2. **Provisione VPS novo** (ou format + reinstall do existente).
3. **Execute bootstrap via Ansible** (este repo) — ver [`BOOTSTRAP.md`](BOOTSTRAP.md):
   ```bash
   # Inventory/hosts.yml temporariamente com ansible_user: root
   # (só durante bootstrap; o playbook mesmo harden)
   ansible-playbook -i inventory/prod playbooks/setup_vps.yml
   ```
4. **Restore de backup** — mas **só dados**, nunca código/config. Se tinha `postgres_data` volume, restaure. Se tinha `vaultwarden_data`, restaure.
5. **Re-deploy apps** — rebuild imagens Docker do código fonte no GitHub (source of truth), não pull de imagens velhas que podem ter sido tampered.

## 6. Credential rotation (obrigatório após compromise)

Mesmo com VPS formatada, assume-se que credenciais que passaram por lá podem ter vazado:

### 6.1. SSH keys
- **Do seu laptop**: gerar par novo (`ssh-keygen -t ed25519 -C "..."`) e adicionar em `deploy_ssh_authorized_keys` do inventory.
- Apagar par antigo do laptop + revogar em todos os servidores onde estava.

### 6.2. Ansible Vault
- Gerar senha master nova (`~/.ansible-vault/aerobi-prod`).
- Re-criptografar cada value:
  ```bash
  # Descriptografa cada secret, anota, gera nova senha, re-encripta:
  for key in $(grep "^vault_" inventory/prod/group_vars/all/vault.yml | cut -d: -f1); do
    ansible localhost -m debug -a "var=$key" \
      -e "@inventory/prod/group_vars/all/vault.yml" --connection=local
  done
  # Trocar ~/.ansible-vault/aerobi-prod pela nova senha
  # Apagar vault.yml antigo
  # Re-adicionar cada secret com ansible-vault encrypt_string usando nova senha
  ```

### 6.3. DB passwords
- Gerar novas para cada `vault_*_db_password`.
- Aplicar via `ansible-playbook setup_app_databases.yml` (role é idempotente: `ALTER USER` atualiza senha de user existente).

### 6.4. MinIO root password
- Rotacionar `vault_minio_root_password` + reaplicar `setup_minio.yml`.
- Apps que usam access keys derivadas precisam regerar (root muda primeiro, keys depois).

### 6.5. Headscale
- **Re-emitir pre-auth keys** para todos os tags (`tag:vps`, `tag:dev`, `tag:airfield`).
- Forçar re-login de todos os nodes na tailnet (`headscale nodes expire <id>`).

### 6.6. Third-party tokens
- GitHub PAT/Actions secrets
- Hostinger API tokens
- SMTP providers (Vaultwarden usa Google Workspace)
- **Rotate all**. Preferível assume-compromised do que assume-safe.

### 6.7. Domínio + DNS
- Verificar NS de `aerobi.com.br` (comparar com o que deveria ser):
  ```bash
  dig NS aerobi.com.br +short
  # Esperado: a.dns.br., b.dns.br., c.dns.br.
  ```
- Se atacante mudou NS para direcionar para servidor dele, reverter no Registro.br.

## 7. Pós-rebuild — prevention

Depois de tudo reconstruído:

- [ ] Fail2ban ativo (`sudo fail2ban-client status`)
- [ ] UFW restrito (`sudo ufw status` mostra só 22, 80, 443 + UDP 41641)
- [ ] SSH root disabled (`grep PermitRootLogin /etc/ssh/sshd_config`)
- [ ] Password auth disabled (`grep PasswordAuthentication /etc/ssh/sshd_config`)
- [ ] NOPASSWD deploy via sudoers.d
- [ ] Automatic security updates (`unattended-upgrades`)
- [ ] **Uptime Kuma com Domain Name Expiry monitor** para `aerobi.com.br`
- [ ] Backup automatizado agendado (issue futura — para `aerobi-prod-backups` no MinIO)
- [ ] SSH keys com passphrase — NÃO deixar chaves raw no disco
- [ ] Endpoints admin tailnet-only (`s3-console`, `status`, `/admin`)
- [ ] Secret scanning (GitHub native ou GitGuardian)

## 8. Sinais de alerta que valem investigação

- Container "unhealthy" por muito tempo sem deploy novo
- DNS de `aerobi.com.br` apontando para IP que você não reconhece
- `docker ps` mostrando container com imagem desconhecida
- `sudo last | head -20` mostra login que você não fez
- `sudo lastb` com muitas tentativas falhadas recentes (brute force)
- Processos consumindo CPU sem razão (miner, botnet)
- Tráfego saindo em portas incomuns (`ss -tnp`)
- Modificação recente em `/etc/passwd`, `/etc/sudoers`, `/root/.ssh/authorized_keys`
- Binários novos em `/usr/local/bin`, `/tmp`, `/var/tmp`
- **Node novo na tailnet sem você ter aprovado** (`docker exec headscale headscale nodes list`)

## 9. Quando chamar especialista

Se alguma dessas:
- Dados de usuário do `aerobi-api` vazaram
- Pagamentos foram processados na VPS comprometida
- Há regulação (LGPD) que obriga reporte (90% dos casos com PII)
- Atacante parece ter persistência sofisticada (rootkit kernel-level)
- Não tem expertise interna para análise forense

Contrate IR (Incident Response) profissional. Empresas como Mandiant, CrowdStrike, ou nacionais como Tempest/TIVIT têm pacotes emergenciais.

## 10. Lições aprendidas — registrar

Depois do incidente resolvido, escrever post-mortem:
- O que aconteceu
- Como foi descoberto
- Qual o vetor de entrada (se identificado)
- O que foi perdido/exposto
- O que foi feito para resolver
- O que muda daqui para frente (controls novos, mudanças de processo)

Commitar no repo como `docs/postmortem-YYYY-MM-DD.md`.
