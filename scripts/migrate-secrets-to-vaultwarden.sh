#!/usr/bin/env bash
# migrate-secrets-to-vaultwarden.sh
#
# Lê o vault.yml do Ansible localmente, decripta cada secret via
# ansible-vault, e cria items agrupados por serviço na org "Aerobi"
# do Vaultwarden via bw CLI.
#
# IDEMPOTENTE: se item já existe (mesmo nome + mesma collection),
# faz update em vez de criar duplicado.
#
# PRINCÍPIOS DE SEGURANÇA:
#   - Roda LOCALMENTE no laptop (não na VPS).
#   - Senhas decriptadas vão direto pelo pipe para bw — nada toca disco.
#   - Nada é logado em plaintext. set -x está OFF intencionalmente.
#   - Em caso de erro no meio, items já criados ficam (idempotência cobre).
#
# DUAS SENHAS DIFERENTES (atenção pra não confundir!):
#   1. Master do BITWARDEN (do seu user no Vaultwarden, mesma do login
#      em https://vault.aerobi.com.br). Pedida pelo `bw unlock`.
#   2. Master do ANSIBLE VAULT (~/.ansible-vault/aerobi-prod).
#      NÃO é pedida — o ansible.cfg aponta para esse arquivo, decripta
#      automaticamente. Só falha se o arquivo estiver com a senha errada.
#
# USO:
#   1. Instalar bw CLI: npm install -g @bitwarden/cli
#   2. Configurar:  bw config server https://vault.aerobi.com.br
#   3. Login com user OWNER ou ADMIN da org Aerobi:
#        bw login <email-do-owner>
#      (User comum não consegue criar Collections — vai dar 401)
#   4. Conectar à tailnet:  sudo tailscale up
#   5. Rodar:  ./scripts/migrate-secrets-to-vaultwarden.sh
#
# COLLECTIONS: Se alguma Collection esperada não existir, o script a
# cria automaticamente via 'bw create org-collection'. Idempotente:
# rodar de novo não duplica nada. Requer user OWNER/ADMIN.
#
# DEPENDÊNCIAS: bw, ansible, jq, python3

# Suprime "DeprecationWarning: punycode module is deprecated" do Node,
# que polui o output do bw CLI sem afetar a operação.
export NODE_OPTIONS="--no-deprecation"

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuração
# -----------------------------------------------------------------------------

ORG_NAME="${ORG_NAME:-Aerobi}"
VAULT_FILE="${VAULT_FILE:-inventory/prod/group_vars/all/vault.yml}"
ANSIBLE_INVENTORY="${ANSIBLE_INVENTORY:-inventory/prod}"

# Collections esperadas (criadas previamente via UI do Vaultwarden).
# Mapeamento item → collection ocorre no SECRETS_MAP abaixo.
declare -A COLLECTION_NAMES=(
  [INFRA]="Infrastructure"
  [APPS]="Applications"
  [NETWORK]="Network & VPN"
  [SERVICES]="Services & Admin"
  [EXTERNAL]="External & Third-Party"
)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

err()    { printf "✗ %s\n" "$*" >&2; exit 1; }
ok()     { printf "✓ %s\n" "$*"; }
info()   { printf "→ %s\n" "$*"; }
banner() {
  printf "\n"
  printf "═══════════════════════════════════════════════════════════════\n"
  printf "  %s\n" "$@"
  printf "═══════════════════════════════════════════════════════════════\n"
  printf "\n"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Comando '$1' não encontrado. Instale antes de prosseguir."
}

decrypt_secret() {
  # Decripta um secret do vault.yml SEM expor no stdout do shell pai.
  # Retorna pelo stdout o valor em plaintext, pronto para pipe.
  local name="$1"
  ansible localhost \
    -m debug -a "var=${name}" \
    -e "@${VAULT_FILE}" \
    --connection=local 2>/dev/null \
    | python3 -c "
import sys, json, re
data = sys.stdin.read()
m = re.search(r'\"' + sys.argv[1] + r'\": \"(.+?)\"', data, re.DOTALL)
if not m:
    sys.exit(1)
print(m.group(1), end='')
" "$name"
}

get_org_id() {
  bw list organizations | jq -r --arg n "$ORG_NAME" '.[] | select(.name==$n) | .id'
}

get_collection_id() {
  local org_id="$1" coll_name="$2"
  bw list collections --organizationid "$org_id" \
    | jq -r --arg n "$coll_name" '.[] | select(.name==$n) | .id'
}

get_existing_item_id() {
  # Retorna o id do item se já existir na org (busca por nome exato).
  local org_id="$1" item_name="$2"
  bw list items --organizationid "$org_id" \
    | jq -r --arg n "$item_name" '.[] | select(.name==$n) | .id' \
    | head -n1
}

ensure_collection() {
  # Cria a Collection se não existir, mantendo idempotência.
  # Requer que o user logado seja owner/admin da org.
  #
  # Constrói o JSON do zero (sem usar `bw get template` que vem com
  # placeholder de group inválido — causa "Invalid member" no servidor).
  local org_id="$1" coll_name="$2"
  local existing_id
  existing_id=$(get_collection_id "$org_id" "$coll_name")
  if [ -n "$existing_id" ]; then
    ok "Collection '$coll_name' já existe (id=${existing_id:0:8}...)"
    return 0
  fi

  info "Criando Collection '$coll_name' na org"

  local payload
  payload=$(jq -nc \
    --arg org "$org_id" \
    --arg name "$coll_name" \
    '{
      organizationId: $org,
      name: $name,
      externalId: null,
      groups: [],
      users: []
    }')

  # Tenta criar. Captura stderr+stdout para diagnóstico se falhar.
  local create_output
  if ! create_output=$(echo "$payload" | bw encode | bw create org-collection --organizationid "$org_id" 2>&1); then
    err "Falha ao criar Collection '$coll_name'.\n  Output do bw: $create_output\n  JSON enviado: $payload\n  Diagnóstico:\n    bw get template org-collection   # ver template atual\n    bw list collections --organizationid $org_id   # ver collections já existentes"
  fi

  bw sync >/dev/null
  ok "Collection criada: '$coll_name'"
}

# Cria ou atualiza um item login agrupado.
# Args:
#   $1 = collection key (INFRA, APPS, NETWORK, SERVICES, EXTERNAL)
#   $2 = item name
#   $3 = JSON do item (sem organizationId/collectionIds — adicionados aqui)
upsert_item() {
  local coll_key="$1" item_name="$2" item_json="$3"
  local coll_name="${COLLECTION_NAMES[$coll_key]}"
  local coll_id; coll_id=$(get_collection_id "$ORG_ID" "$coll_name")
  [ -z "$coll_id" ] && err "Collection '$coll_name' não existe na org. Crie via UI primeiro."

  local payload
  payload=$(echo "$item_json" | jq \
    --arg org "$ORG_ID" \
    --arg coll "$coll_id" \
    '.organizationId = $org | .collectionIds = [$coll]')

  local existing_id; existing_id=$(get_existing_item_id "$ORG_ID" "$item_name")
  if [ -n "$existing_id" ]; then
    info "Atualizando '$item_name' (id=$existing_id) → [$coll_name]"
    echo "$payload" | bw encode | bw edit item "$existing_id" >/dev/null
    ok "Atualizado: $item_name"
  else
    info "Criando '$item_name' → [$coll_name]"
    echo "$payload" | bw encode | bw create item >/dev/null
    ok "Criado: $item_name"
  fi
}

# Builder de field "hidden" (type 1)
field_hidden() { jq -nc --arg n "$1" --arg v "$2" '{name:$n, value:$v, type:1}'; }
field_text()   { jq -nc --arg n "$1" --arg v "$2" '{name:$n, value:$v, type:0}'; }

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

info "Verificando dependências"
need_cmd bw
need_cmd ansible
need_cmd jq
need_cmd python3

[ -f "$VAULT_FILE" ] || err "Vault file não encontrado: $VAULT_FILE (rode da raiz do repo)"

info "Verificando status do bw CLI"
BW_STATUS=$(bw status | jq -r .status)
case "$BW_STATUS" in
  unauthenticated)
    err "Não logado no bw. Rode primeiro: bw login <email-do-owner-da-org-Aerobi>"
    ;;
  locked)
    banner \
      "PRÓXIMO PASSO — DIGITE SUA MASTER PASSWORD DO BITWARDEN" \
      "" \
      "É a mesma senha que você usa para entrar em" \
      "  https://vault.aerobi.com.br" \
      "" \
      "NÃO é a senha do Ansible Vault — essa só será usada depois," \
      "automaticamente, lendo de ~/.ansible-vault/aerobi-prod"
    export BW_SESSION=$(bw unlock --raw)
    ;;
  unlocked)
    ok "Bw já está unlocked (sessão anterior ainda válida)"
    ;;
  *)
    err "Status bw desconhecido: $BW_STATUS"
    ;;
esac

bw sync >/dev/null
ok "Bw sync ok"

# Identificar user logado para diagnóstico
USER_EMAIL=$(bw status | jq -r .userEmail)
ok "Logado no bw como: $USER_EMAIL"

ORG_ID=$(get_org_id) || true
[ -z "${ORG_ID:-}" ] && err "Org '$ORG_NAME' não encontrada no seu cofre (user $USER_EMAIL). Crie via UI ou convide este user pra org."
ok "Org '$ORG_NAME' encontrada (id=${ORG_ID:0:8}...)"

# Validar role na org (0=Owner, 1=Admin, 2=User, 3=Manager).
# Só Owner/Admin pode criar Collections via API.
USER_ROLE=$(bw list organizations | jq -r --arg id "$ORG_ID" '.[] | select(.id==$id) | .type')
ROLE_NAME=""
case "$USER_ROLE" in
  0) ROLE_NAME="Owner"   ;;
  1) ROLE_NAME="Admin"   ;;
  2) ROLE_NAME="User"    ;;
  3) ROLE_NAME="Manager" ;;
  *) ROLE_NAME="Desconhecido (type=$USER_ROLE)" ;;
esac

if [ "$USER_ROLE" = "0" ] || [ "$USER_ROLE" = "1" ]; then
  ok "Role do user na org: $ROLE_NAME (permite criar Collections e Items na org)"
else
  err "Role do user $USER_EMAIL na org é '$ROLE_NAME', não Owner/Admin.\n  Para rodar este script, faça:\n    bw logout && bw login <email-do-owner>\n  Ou eleve este user a Admin/Owner pela UI da org Aerobi → Members."
fi

# Garante que todas as collections necessárias existem (cria as faltantes).
# Ordem dentro do array é não-determinística (associative); para output
# consistente, iteramos uma lista ordenada por nome.
info "Garantindo Collections esperadas (cria faltantes automaticamente)"
for key in INFRA APPS NETWORK SERVICES EXTERNAL; do
  ensure_collection "$ORG_ID" "${COLLECTION_NAMES[$key]}"
done

# -----------------------------------------------------------------------------
# Decryption de todos os secrets de uma vez (em variáveis locais)
# -----------------------------------------------------------------------------

banner \
  "Decriptando 11 secrets do vault.yml do Ansible" \
  "" \
  "Não vai pedir senha — ansible.cfg aponta para" \
  "  ~/.ansible-vault/aerobi-prod" \
  "que é a master do Ansible Vault. Se falhar, confira que esse" \
  "arquivo existe e tem a master correta."

# Cada variável fica em memória deste shell, nunca em disco.
POSTGRES_PASS=$(decrypt_secret vault_postgres_password) || err "Falha decripta postgres"
AEROBI_DB_PASS=$(decrypt_secret vault_aerobi_db_password) || err "Falha decripta aerobi_db"
VW_DB_PASS=$(decrypt_secret vault_vaultwarden_db_password) || err "Falha decripta vw_db"
VW_ADMIN_TOKEN=$(decrypt_secret vault_vaultwarden_admin_token) || err "Falha decripta vw_admin"
VW_SMTP_PASS=$(decrypt_secret vault_vaultwarden_smtp_password) || err "Falha decripta vw_smtp"
HEADSCALE_DB_PASS=$(decrypt_secret vault_headscale_db_password) || err "Falha decripta headscale_db"
HEADSCALE_AUTHKEY=$(decrypt_secret vault_headscale_authkey_vps) || err "Falha decripta headscale_authkey"
DEPLOY_PASS=$(decrypt_secret vault_deploy_password) || err "Falha decripta deploy"
VALKEY_PASS=$(decrypt_secret vault_valkey_password) || err "Falha decripta valkey"
MINIO_PASS=$(decrypt_secret vault_minio_root_password) || err "Falha decripta minio"
SFTPGO_ADMIN_PASS=$(decrypt_secret vault_sftpgo_admin_password) || err "Falha decripta sftpgo"

ok "Todos os 11 secrets decriptados em memória"

# -----------------------------------------------------------------------------
# Construção dos items e upsert
# -----------------------------------------------------------------------------

info "Construindo e enviando items para a org '$ORG_NAME'"

# 1. Postgres + DBs por app (Infrastructure)
POSTGRES_ITEM=$(jq -n \
  --arg pass "$POSTGRES_PASS" \
  --argjson f1 "$(field_hidden "aerobi_user_password" "$AEROBI_DB_PASS")" \
  --argjson f2 "$(field_text   "aerobi_user_name"     "aerobi_user")" \
  --argjson f3 "$(field_hidden "vaultwarden_user_password" "$VW_DB_PASS")" \
  --argjson f4 "$(field_text   "vaultwarden_user_name"     "vaultwarden_user")" \
  --argjson f5 "$(field_hidden "headscale_user_password" "$HEADSCALE_DB_PASS")" \
  --argjson f6 "$(field_text   "headscale_user_name"     "headscale_user")" \
  '{
    name: "Postgres Aerobi",
    type: 1,
    notes: "Postgres 17 container.\nBind: 127.0.0.1:5432 (apps) + 100.64.0.1:5432 (tailnet via socat sidecar).\nVer docs/DATABASES.md para detalhes por app.",
    login: {
      username: "postgres",
      password: $pass,
      uris: [
        {uri: "postgres://postgres@127.0.0.1:5432/postgres", match: null},
        {uri: "postgres://postgres@100.64.0.1:5432/postgres", match: null}
      ]
    },
    fields: [$f1, $f2, $f3, $f4, $f5, $f6]
  }')
upsert_item INFRA "Postgres Aerobi" "$POSTGRES_ITEM"

# 2. Valkey (Infrastructure)
VALKEY_ITEM=$(jq -n --arg pass "$VALKEY_PASS" '
{
  name: "Valkey (cache)",
  type: 1,
  notes: "Fork OSS do Redis. Cache + filas + sessões. Sem vhost — apps acessam via rede docker warpgate.",
  login: {
    username: "default",
    password: $pass,
    uris: [{uri: "redis://default:senha@valkey:6379", match: null}]
  },
  fields: []
}')
upsert_item INFRA "Valkey (cache)" "$VALKEY_ITEM"

# 3. MinIO (Infrastructure)
MINIO_ITEM=$(jq -n --arg pass "$MINIO_PASS" '
{
  name: "MinIO (object storage)",
  type: 1,
  notes: "Object storage S3-compatible.\nBuckets: aerobi-prod-uploads, aerobi-prod-backups.\nConsole admin: tailnet-only.",
  login: {
    username: "aerobi-admin",
    password: $pass,
    uris: [
      {uri: "https://s3-console.aerobi.com.br", match: null},
      {uri: "https://s3.aerobi.com.br", match: null}
    ]
  },
  fields: []
}')
upsert_item INFRA "MinIO (object storage)" "$MINIO_ITEM"

# 4. VPS Deploy User (Network & VPN)
DEPLOY_ITEM=$(jq -n --arg pass "$DEPLOY_PASS" '
{
  name: "VPS Deploy User (SSH)",
  type: 1,
  notes: "Usuário deploy na VPS Hostinger.\nLogin SSH normalmente é por chave; esta senha é fallback para sudo NOPASSWD não estar ativo / recovery.",
  login: {
    username: "deploy",
    password: $pass,
    uris: [{uri: "ssh://deploy@187.127.6.20", match: null}]
  },
  fields: []
}')
upsert_item NETWORK "VPS Deploy User (SSH)" "$DEPLOY_ITEM"

# 5. Headscale VPS Pre-Auth Key (Network & VPN) — secure note pois não é login
HEADSCALE_ITEM=$(jq -n --arg key "$HEADSCALE_AUTHKEY" --argjson f "$(field_hidden "preauth_key" "$HEADSCALE_AUTHKEY")" '
{
  name: "Headscale VPS Pre-Auth Key",
  type: 2,
  notes: "Pre-auth key reusável para a VPS aerobi-vps reconectar à tailnet.\nExpiração: 90 dias (regerar via: docker exec headscale headscale preauthkeys create --user aerobi --reusable --expiration 90d --tags tag:vps).\nTags: tag:vps",
  secureNote: {type: 0},
  fields: [$f]
}')
upsert_item NETWORK "Headscale VPS Pre-Auth Key" "$HEADSCALE_ITEM"

# 6. Vaultwarden Admin (Services & Admin)
VW_ADMIN_ITEM=$(jq -n --arg tok "$VW_ADMIN_TOKEN" --argjson f "$(field_hidden "admin_token" "$VW_ADMIN_TOKEN")" '
{
  name: "Vaultwarden Admin Token",
  type: 1,
  notes: "Token de acesso ao painel /admin do próprio Vaultwarden.\nUsado em curl Authorization: Bearer <token>.\nAcesso via tailnet (vhost path-level allow 100.64.0.0/10).",
  login: {
    username: "admin",
    password: $tok,
    uris: [{uri: "https://vault.aerobi.com.br/admin", match: null}]
  },
  fields: [$f]
}')
upsert_item SERVICES "Vaultwarden Admin Token" "$VW_ADMIN_ITEM"

# 7. SFTP Go Admin (Services & Admin)
SFTPGO_ITEM=$(jq -n --arg pass "$SFTPGO_ADMIN_PASS" '
{
  name: "SFTP Go Web Admin",
  type: 1,
  notes: "Admin do web UI do SFTP Go (criar/editar users SFTP).\nAcesso: tailnet (vhost tailnet-only).\nUsers SFTP de fato são criados pela UI e ficam na tabela users do SQLite.",
  login: {
    username: "admin",
    password: $pass,
    uris: [{uri: "https://sftp.aerobi.com.br/web/admin", match: null}]
  },
  fields: []
}')
upsert_item SERVICES "SFTP Go Web Admin" "$SFTPGO_ITEM"

# 8. Vaultwarden SMTP (External & Third-Party)
SMTP_ITEM=$(jq -n --arg pass "$VW_SMTP_PASS" '
{
  name: "Vaultwarden SMTP (Gmail)",
  type: 1,
  notes: "App password do Gmail usado pelo Vaultwarden para enviar convites + alertas.\nConta: admin@aerobi.com.br.\nGerada em myaccount.google.com → Security → App passwords.\nRevogar lá se vazar.",
  login: {
    username: "admin@aerobi.com.br",
    password: $pass,
    uris: [{uri: "smtp://smtp.gmail.com:587", match: null}]
  },
  fields: []
}')
upsert_item EXTERNAL "Vaultwarden SMTP (Gmail)" "$SMTP_ITEM"

# -----------------------------------------------------------------------------
# Final
# -----------------------------------------------------------------------------

echo
ok "Migração concluída. 8 items na org '$ORG_NAME'."
info "Verifique pela UI em https://vault.aerobi.com.br/#/vault?selectedVault=$ORG_ID"
echo
info "Próximos passos:"
echo "  1. Confirmar que cada item está na collection certa (UI mostra a coluna 'Collections')"
echo "  2. Ativar 2FA no seu user master se ainda não fez (Account → Two-step Login)"
echo "  3. Considerar habilitar Vaultwarden Send para compartilhar credenciais 1-time-link"
echo "  4. Ver docs/automacoes/vaultwarden.md para próximas automações (backup, audit, canário)"
