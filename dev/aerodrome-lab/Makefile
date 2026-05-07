.PHONY: keys up down ssh smoketest playbook camera-test logs status clean help

SSH_KEY := ssh/id_ed25519
LAB_DIR := $(shell pwd)
ANSIBLE_DIR := $(shell cd ../.. && pwd)

help:
	@echo "Aerobi aerodrome-lab — alvos disponíveis:"
	@echo ""
	@echo "  make up           Sobe lab (raspi-sim + 4 fake-cameras)"
	@echo "  make down         Derruba lab (preserva volumes)"
	@echo "  make ssh          Conecta no raspi-sim via SSH"
	@echo "  make smoketest    Valida que ansible alcança o raspi-sim (ping)"
	@echo "  make playbook     Roda setup_aerodrome.yml contra raspi-sim (--skip-tags tailscale)"
	@echo "  make camera-test  Verifica do raspi-sim que cada câmera fake serve RTSP"
	@echo "  make logs         Tail dos logs de todos os containers"
	@echo "  make status       Status dos containers"
	@echo "  make clean        Derruba tudo e apaga chaves SSH (reset total)"
	@echo ""

keys:
	@if [ ! -f $(SSH_KEY) ]; then \
		mkdir -p ssh; \
		ssh-keygen -t ed25519 -N "" -f $(SSH_KEY) -C "aerobi-aerodrome-lab" -q; \
		cp $(SSH_KEY).pub ssh/authorized_keys; \
		echo "✓ SSH keys geradas em $(SSH_KEY)"; \
	else \
		echo "✓ SSH keys já existem em $(SSH_KEY)"; \
	fi

up: keys
	docker compose build
	docker compose up -d
	@echo ""
	@echo "Lab subiu. Aguarde ~5s pra SSH ficar pronto."
	@echo ""
	@echo "  Acessar raspi-sim:    make ssh"
	@echo "  Rodar Ansible:        make playbook"
	@echo "  Ver câmeras servindo: make camera-test"
	@echo ""

down:
	docker compose down

ssh:
	ssh -i $(SSH_KEY) -p 2222 \
	    -o StrictHostKeyChecking=no \
	    -o UserKnownHostsFile=/dev/null \
	    deploy@localhost

smoketest:
	@cd $(ANSIBLE_DIR) && ansible \
	    -i inventory/dev-aerodrome \
	    -m ping \
	    all

playbook:
	@cd $(ANSIBLE_DIR) && ansible-playbook \
	    -i inventory/dev-aerodrome \
	    playbooks/setup_aerodrome.yml \
	    --skip-tags tailscale

camera-test:
	@echo "Validando que o raspi-sim alcança as 4 câmeras fake (TCP + ICMP)..."
	@docker compose exec raspi-sim sh -c '\
		for ip in 91 92 93 94; do \
			n=$$((ip - 90)); \
			ping -c 1 -W 1 192.168.68.$$ip >/dev/null 2>&1 \
				&& echo "  cam-$$n  192.168.68.$$ip  ICMP OK" \
				|| echo "  cam-$$n  192.168.68.$$ip  ICMP FAIL"; \
			(timeout 1 bash -c "</dev/tcp/192.168.68.$$ip/8554" 2>/dev/null) \
				&& echo "  cam-$$n  192.168.68.$$ip:8554 RTSP TCP OK" \
				|| echo "  cam-$$n  192.168.68.$$ip:8554 RTSP TCP FAIL"; \
		done \
	'
	@echo ""
	@echo "Para validar HLS depois que mediamtx for instalado no raspi-sim:"
	@echo "  curl -sI http://localhost:8888/cam-1/index.m3u8  # de dentro do raspi-sim"

logs:
	docker compose logs -f

status:
	docker compose ps

clean:
	docker compose down -v
	rm -rf ssh/id_ed25519 ssh/id_ed25519.pub ssh/authorized_keys
	@echo "✓ Lab limpo. Próximo 'make up' gera chaves novas."
