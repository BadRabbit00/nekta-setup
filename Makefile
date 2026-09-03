# Управление площадкой Nekta.
#
#   make help            список целей
#   make lint            ansible-lint + yamllint + shellcheck
#   make preflight       проверка железа и сети без изменений
#   make site            полная настройка обоих серверов

ANSIBLE_PLAYBOOK ?= ansible-playbook
VAULT_ARGS       ?= --ask-vault-pass
LIMIT            ?=
EXTRA            ?=
PB               := $(ANSIBLE_PLAYBOOK) $(VAULT_ARGS) $(if $(LIMIT),--limit $(LIMIT),) $(EXTRA)

.PHONY: help deps lint yamllint shellcheck syntax check preflight bootstrap \
        site nekta backup ups backup-run backup-status ups-test facts

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

deps: ## Установить коллекции Ansible
	ansible-galaxy collection install -r requirements.yml

lint: yamllint shellcheck ## Все проверки кода
	ansible-lint

yamllint: ## Проверить оформление YAML
	yamllint .

shellcheck: ## Проверить скрипты резервного копирования и ИБП
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck roles/backup_server/files/* roles/firewall/files/* || exit 1; \
	else \
	  echo "shellcheck не установлен — проверяется только синтаксис bash"; \
	  for f in roles/backup_server/files/* roles/firewall/files/*; do \
	    bash -n "$$f" || exit 1; echo "  OK $$f"; \
	  done; \
	fi
	@echo "Скрипты-шаблоны (.j2) — проверка синтаксиса bash после подстановки:"
	@for f in roles/nut/templates/upssched-cmd.j2 \
	          roles/nut/templates/nekta-ups-shutdown.j2 \
	          roles/nekta_prep/templates/nekta-predump.j2; do \
	  sed 's/{%[^%]*%}//g; s/{{[^}]*}}/X/g' "$$f" | bash -n - || exit 1; \
	  echo "  OK $$f"; \
	done

syntax: ## Синтаксический разбор всех плейбуков
	@for pb in playbooks/*.yml; do \
	  echo "== $$pb"; $(ANSIBLE_PLAYBOOK) --syntax-check $$pb >/dev/null || exit 1; \
	done
	@echo "Синтаксис в порядке"

check: ## Прогон site.yml без изменений (--check)
	$(PB) playbooks/site.yml --check --diff

preflight: ## Проверка железа и доступности сети
	$(PB) playbooks/preflight.yml

bootstrap: ## Первичная подготовка чистой ОС (python3)
	$(ANSIBLE_PLAYBOOK) playbooks/bootstrap.yml -k -K

site: ## Настроить оба сервера
	$(PB) playbooks/site.yml

nekta: ## Настроить только сервер приложения
	$(PB) playbooks/nekta.yml

backup: ## Настроить только сервер резервного копирования
	$(PB) playbooks/backup.yml

ups: ## Настроить ИБП на обоих серверах
	$(PB) playbooks/ups.yml

backup-run: ## Снять резервную копию сейчас
	$(PB) playbooks/backup-run.yml

backup-status: ## Показать состояние копий
	ansible backup -b -a /usr/local/sbin/nekta-backup-status

ups-test: ## Опросить ИБП
	$(PB) playbooks/ups-test.yml

facts: ## Показать характеристики серверов
	ansible all -b -m setup -a 'filter=ansible_processor*,ansible_memtotal_mb,ansible_mounts'
