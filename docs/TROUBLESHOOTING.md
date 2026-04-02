# Problemas comuns e soluções

---

## Erro: "Permission denied (publickey)"

**Causa:** chave SSH não configurada ou IP banido pelo Fail2Ban.

**Solução:**
```bash
# Verificar se a chave está sendo usada
ssh -v -i ~/.ssh/id_ed25519 root@IP_DA_VPS

# Se for IP banido, acessar via console da Hostinger e rodar:
fail2ban-client unban SEU_IP
```

---

## Erro: "UNREACHABLE! Connection refused"

**Causa:** porta 22 bloqueada (Fail2Ban ou firewall) ou SSH não está rodando.

**Solução:**
```bash
# Acessar via console da Hostinger e verificar:
systemctl status ssh
fail2ban-client status sshd
fail2ban-client unban SEU_IP
```

---

## Erro: "sudo: a password is required"

**Causa:** o usuário não tem sudo sem senha configurado, e o Ansible não consegue elevar privilégios.

**Solução 1:** rodar como root inicialmente
```yaml
# inventory/hosts.yml
ansible_user: root
```

**Solução 2:** passar a senha sudo via flag
```bash
ansible-playbook -i inventory/hosts.yml playbooks/setup_vps.yml --ask-become-pass
```

---

## Erro: "Could not find or access inventory file"

**Causa:** caminho errado para o inventário.

**Solução:** sempre rodar os comandos da raiz do projeto:
```bash
cd ~/projects/ansible-vps
ansible-playbook -i inventory/hosts.yml playbooks/setup_vps.yml
```

---

## Playbook rodou mas SSH ficou inacessível depois

**Causa:** a role `ssh_hardening` desabilitou autenticação por senha antes de adicionar a chave SSH.

**Solução:** acessar via console da Hostinger e verificar:
```bash
cat /home/deploy/.ssh/authorized_keys
# A chave deve estar lá

# Se não estiver, adicionar manualmente:
echo "SUA_CHAVE_PUBLICA" >> /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
```

---

## Docker: "permission denied while trying to connect to the Docker daemon"

**Causa:** usuário ainda não tem a sessão SSH atualizada com o grupo `docker`.

**Solução:** reconectar a sessão SSH
```bash
# Desconectar e reconectar
exit
ssh deploy@IP_DA_VPS

# Ou sem reconectar:
newgrp docker
```

---

## Como verificar o que o Ansible vai fazer sem executar (dry-run)

```bash
ansible-playbook -i inventory/hosts.yml playbooks/setup_vps.yml --check
```

---

## Como rodar apenas uma parte do playbook

```bash
# Usar tags
ansible-playbook -i inventory/hosts.yml playbooks/setup_vps.yml --tags docker

# Pular uma role específica
ansible-playbook -i inventory/hosts.yml playbooks/setup_vps.yml --skip-tags nginx
```

---

## Como testar se o Ansible consegue conectar

```bash
ansible -i inventory/hosts.yml all -m ping
```

Resposta esperada:
```
vps-hostinger | SUCCESS => { "ping": "pong" }
```
