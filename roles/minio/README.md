# Role: minio

Sobe MinIO (S3-compatible object storage) via Docker na rede `warpgate`. Reutilizável — cada projeto declara seus buckets no inventory.

## Segurança

- **Produção**: portas 9000/9001 expostas apenas em `127.0.0.1` (localhost). Acesso público somente via nginx reverse proxy com TLS (`setup_app.yml`).
- **Dev**: `minio_bind_address` pode ser `0.0.0.0` pra facilitar debugging direto no `:9000`/`:9001`.
- Credenciais **nunca** em plaintext no repo de prod — use `ansible-vault encrypt_string`.

## Rede

- Container conectado à rede `warpgate` (mesma do postgres, apps).
- Apps se conectam internamente usando hostname: `minio:9000`.

## Variáveis

Ver `defaults/main.yml`. As principais:

| Var                    | Default                          | Descrição                                                         |
|------------------------|----------------------------------|-------------------------------------------------------------------|
| `minio_root_user`      | `minioadmin`                     | Usuário root (sobrescreva)                                        |
| `minio_root_password`  | `changeme`                       | Senha root (**obrigatório sobrescrever** — role falha se default) |
| `minio_bind_address`   | `127.0.0.1`                      | `127.0.0.1` em prod, `0.0.0.0` em dev                             |
| `minio_data_dir`       | `/home/{{ deploy_user }}/minio/data` | Disco persistente                                             |
| `minio_buckets`        | `[]`                             | Lista declarativa de buckets a criar                              |
| `minio_container_uid`  | `1000` (default), `1001` em prod | Owner dos arquivos no host                                        |

## Exemplo de uso (inventory)

```yaml
# inventory/prod/group_vars/all/all.yml
minio_root_user: aerobi-admin
minio_root_password: "{{ vault_minio_root_password }}"
minio_bind_address: "127.0.0.1"
minio_container_uid: 1001
minio_container_gid: 1001
minio_buckets:
  - name: aerobi-prod-uploads
    public_read: false
  - name: aerobi-prod-backups
    public_read: false
```

Depois: `ansible-vault edit inventory/prod/group_vars/all/vault.yml` e adicionar `vault_minio_root_password`.

## Aplicar

```bash
# Prod (default)
ansible-playbook playbooks/setup_minio.yml

# Dev
ansible-playbook -i inventory/dev playbooks/setup_minio.yml
```

Idempotente — seguro rodar múltiplas vezes.

## Expor publicamente com TLS

Use o playbook `setup_app.yml` existente, uma vez por subdomínio. Convenção do alvo: ambos vivem em `aerobi.com.br` (ver [docs/DOMINIOS.md](../../docs/DOMINIOS.md) quando criado).

```bash
# API S3 — público (apps externos consomem via SDK AWS v3)
# vhost_client_max_body_size é obrigatório pra uploads > 1MB
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=minio_api app_domain=s3.aerobi.com.br app_port=9000 vhost_client_max_body_size=25m"

# Console web (painel admin) — TAILNET-ONLY, não há motivo para expor
# externamente. WebSocket obrigatório (object browser usa wss://).
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=minio_console app_domain=s3-console.aerobi.com.br app_port=9001 vhost_websocket_enabled=true vhost_tailnet_only=true"
```

**⚠️ Por que `vhost_tailnet_only=true` no console?** O painel admin do MinIO permite criar/deletar buckets, gerar access keys, etc — endpoints administrativos não devem ficar expostos publicamente. A flag restringe ao range CGNAT da Headscale (`100.64.0.0/10`); admins acessam via `tailscale up` em laptop. Mesmo padrão de `vault.aerobi.com.br/admin`.

**⚠️ `vhost_client_max_body_size`** é obrigatório no vhost da API pra permitir uploads > 1MB (nginx default). Recomendado `25m` pra suportar imagens/vídeos curtos.

## Rotação de credenciais

Root credentials: rotacionar editando vault + re-rodar playbook. O container é re-criado com as novas env vars (dados persistidos no volume).

Buckets individuais com access keys dedicadas: **não implementado nesta versão**. Acessar via root credentials por enquanto. Issue futura pra criar keys por app.

## Fora de escopo

- CORS por bucket (configurável via `mc cors set` — padrão servidor hoje)
- Backup automatizado (`mc mirror` cron)
- MinIO distributed mode (multi-node)
- Prometheus exporter
- Rotação automatizada de keys
