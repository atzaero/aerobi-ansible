# SECURITY.md — aerobi-ansible

Threat model + boas práticas de segurança **deste alvo específico**. É a fonte que o
agente `infra-reviewer` e os comandos `/infra-review` / `/security-audit` aplicam.
Mantenha alinhado com as roles reais.

## Contexto / superfície de ataque

| Item | Valor |
|---|---|
| Alvo | VPS Hostinger **pública**, Ubuntu 24.04, `187.127.6.20` (tailnet `100.64.0.1`) |
| Exposição | nginx (80/443) na internet; SSH (22) restrito; UDP 41641 (Tailscale) |
| Domínios | infra em `aerobi.com.br` (Registro.br); subdomínios admin tailnet-only |
| VPN | **Headscale self-hosted** — control plane Tailscale-compatible NESTE repo |
| Acesso | `ssh deploy@187.127.6.20`, key-only; `deploy` com `NOPASSWD:ALL` |
| Edge | Raspberry Pi (`aerodrome_edge`, subnet router Tailscale) + MediaMTX (RTSP→HLS, câmeras IP) |
| Dados sensíveis | Postgres (DBs de apps), MinIO (objetos), Vaultwarden (cofre), streams de câmera |

**Premissa central:** esta é uma máquina real exposta na internet **e** hospeda o
control plane que comanda a tailnet inteira. Toda mudança é avaliada por "o que isso
abre pra um atacante na porta 443/22 — e o que abre se o Headscale cair?".

## Threat model (o que estamos defendendo)

1. **Vazamento de secret no Git** — senha/chave/pre-auth key commitada em
   role/inventário/template. Impacto: comprometimento direto de
   Postgres/MinIO/Vaultwarden ou da tailnet (Headscale). → Vault per-value.
2. **Exposição acidental de serviço interno** — container com bind `0.0.0.0` fura o
   UFW (Docker NAT, issue #7). Impacto: Postgres/MinIO/Valkey acessíveis da internet.
   → bind `127.0.0.1`, exposição só via nginx.
3. **Exposição tailnet via Docker `-p`** — `-p 100.64.0.1:porta:porta` sofre o mesmo
   NAT bypass do UFW. → exposição tailnet **só** via socat sidecar
   (`network_mode: host`); ver `roles/postgres_tailnet_proxy/`,
   `roles/sftpgo_tailnet_proxy/`.
4. **Comprometimento do control plane Headscale** — **alvo de altíssimo valor**:
   quem o domina emite pre-auth keys e entra na tailnet inteira (acesso a TODOS os
   serviços admin tailnet-only). → API/keys não expostas, ACLs mínimas, segredos do
   Headscale no vault, nunca versionados.
5. **Acesso SSH não autorizado** — brute force, senha fraca, root login. → key-only,
   sem password auth, `MaxAuthTries` baixo, Fail2Ban.
6. **Escalada via `deploy`** — o `NOPASSWD:ALL` é necessário pro Ansible, mas torna o
   `deploy` root-equivalente. → proteger a chave SSH; não replicar NOPASSWD.
7. **Edge exposto** — câmeras RTSP / streams HLS do MediaMTX vazando pra internet
   pública em vez de ficarem restritos à tailnet. → edge acessível só via tailnet.
8. **TLS quebrado / downgrade** — vhost sem `listen 443 ssl` ou cert não emitido. →
   Certbot `--reinstall`, DNS antes do apply.
9. **Credencial default em produção** — serviço sobe com `changeme`. → fail-fast nas
   roles.
10. **vhost tailnet-only mal configurado** — `vhost_tailnet_only=true` sem o extra
    DNS record do Headscale → cliente sai pela internet, nginx vê IP público e
    retorna 403 (config quebrada, não falha de segurança, mas trava o acesso).

## Controles por camada (estado esperado)

### Secrets — Ansible Vault per-value
- Secret real **só** como bloco `!vault | $ANSIBLE_VAULT;1.1;AES256` em
  `inventory/prod/group_vars/all/vault.yml`.
- Default de senha em role = literal `changeme` (placeholder), **nunca** valor real.
- Tasks que manipulam secret usam `no_log: true`.
- Master em `~/.ansible-vault/aerobi-prod`, fora do working tree, nunca commitada.
- ❌ Anti-padrão: senha em `defaults/main.yml`, em `group_vars/all/all.yml`, em
  template `.j2` ou em `debug:`/`msg:`.

### Rede / exposição
- **Docker bind sempre `127.0.0.1:<porta>:<porta>`.** Bind `0.0.0.0` ou IP público =
  vazamento (regras `iptables -t nat` do Docker avaliadas antes do UFW — issue #7).
- **Exposição tailnet = socat sidecar com `network_mode: host`**, escutando direto na
  interface `tailscale0`. **Nunca** `-p 100.64.0.1:porta:porta` (mesmo NAT bypass).
- Exposição externa pública **só** via `nginx_vhost` (terminação TLS).
- `vhost_tailnet_only=true` exige (a) vhost via `setup_app.yml` **E** (b) entrada em
  `headscale_extra_dns_records` (`roles/headscale/defaults/main.yml`) apontando o
  subdomínio para `100.64.0.1` + reaplicar `playbooks/setup_headscale.yml`. Os dois
  passos são complementares.
- UFW (`firewall` role): **deny default** + whitelist mínima (22, 80, 443 + UDP 41641
  do Tailscale em prod). Porta nova exige justificativa documentada em `docs/PORTAS.md`.
- Portas internas conforme `docs/PORTAS.md`.

### Host hardening
- `ssh_hardening`: `PermitRootLogin no`, `PasswordAuthentication no`, `MaxAuthTries`
  baixo, key-only.
- `fail2ban`: jail `sshd` ativo (+ serviços expostos quando aplicável).
- `become`/sudo: `NOPASSWD:ALL` **apenas** no `deploy` (necessidade do Ansible).
  Não criar outros usuários com NOPASSWD; não estreitar a allowlist do `deploy` a
  ponto de quebrar os módulos (rodam `python3` como root).

### Headscale (control plane) — crown jewel
- Segredos do Headscale (noise private key, pre-auth keys, OIDC secrets) **só** no
  vault, nunca versionados nem em log.
- API do Headscale não exposta além do necessário; admin via tailnet.
- ACLs mínimas — não dar acesso amplo a nós que não precisam.
- `headscale_extra_dns_records` é o mecanismo que força tráfego tailnet-only a entrar
  pela mesh (ver `docs/VPN.md`).

### Edge (`aerodrome_edge` / `mediamtx`)
- Raspberry Pi atua como subnet router Tailscale; chaves de auth no vault.
- Streams RTSP/HLS das câmeras **só** acessíveis via tailnet — nunca expostos na
  internet pública.

### TLS / domínios
- vhost via `nginx_vhost` com Certbot `--reinstall` (gotcha de VPS fresh).
- DNS A propagado **antes** do apply (certbot HTTP-01; DNS no Registro.br).
- Infra em `aerobi.com.br`; subdomínios admin resolvem para `100.64.0.1` (tailnet).

### Higiene do repo
- `.gitignore` cobre: `.env`, `.vault_pass*`/`*vault*pass*`, `*.pem`, `*.key`,
  `id_rsa`/`id_ed25519`, `secrets/`, `*.retry`, `.mcp.json`.
- Imagens Docker **pinadas** (tag fixa/digest); sem `:latest` em prod.

## Checklist rápido (pré-PR / pré-prod)

- [ ] Nenhum secret novo fora do `vault.yml` (rodar o grep do `/security-audit`).
- [ ] Toda role com senha tem default `changeme` + task `fail` fail-fast.
- [ ] Nenhum container com bind `0.0.0.0`/IP público.
- [ ] Nenhuma exposição tailnet via `-p 100.64.0.1:...` (só socat sidecar).
- [ ] Todo `vhost_tailnet_only=true` tem extra_record no Headscale (`100.64.0.1`).
- [ ] UFW deny-default intacto; nenhuma porta nova sem justificativa.
- [ ] `ssh_hardening` não enfraquecido.
- [ ] Segredos do Headscale/edge no vault, nunca versionados.
- [ ] vhost novo mantém Certbot `--reinstall`.
- [ ] `no_log: true` nas tasks com secret.
- [ ] `.gitignore` cobre o sensível; nada sensível no diff.
- [ ] Imagens pinadas.

## Resposta a incidente

Triagem detalhada em [`INCIDENT_RESPONSE.md`](INCIDENT_RESPONSE.md). Em caso de
suspeita de comprometimento de secret: **rotacionar o valor no vault** (gerar novo +
reaplicar a role) e revisar logs de acesso — não basta remover do Git, o histórico
permanece. Se o segredo comprometido for do **Headscale** (noise key / pre-auth key):
tratar como incidente de alta gravidade — rotacionar a chave, invalidar nós e
reautenticar a tailnet.

## Fora de escopo (por design)

- WAF / IDS de aplicação (delegado ao nginx/upstream quando aplicável).
- Auditoria de dependências de apps (responsabilidade do CI de cada app, ex:
  `aerobi-api`).
- Backup/DR (ver runbooks de operação).
