# Ansible: сервер Nekta + сервер резервного копирования

Плейбуки готовят два сервера под программный комплекс **Nekta Server** в
профиле **до 10 000 устройств**, настраивают между ними резервное копирование
и обслуживание ИБП с USB-интерфейсом.

```
                    ~~~ электросеть ~~~
                            │
                        ┌───┴────┐
                        │  ИБП   │
                        └─┬────┬─┘
              питание     │    │  USB (состояние, команда на выключение)
        ┌─────────────────┘    └──────────────┐
        │                                     │
┌───────┴────────────┐   pull-копии   ┌───────┴──────────────┐
│  nekta-01          │◄───────────────┤  backup-01           │
│  Nekta Server      │   rsync/SSH    │  снимки + ротация    │
│  /nekta (диск 2)   │                │  /backup (RAID1)     │
│  NUT: netserver    │───────────────►│  NUT: netclient      │
└────────────────────┘  состояние ИБП └──────────────────────┘
```

## Что делают плейбуки, а что нет

Сам **Nekta Server устанавливает вендор** по SSH — по требованиям вендора он
приходит на «чистую» ОС без предустановленных компонентов. Поэтому плейбуки
намеренно **не ставят** docker, СУБД и стек Nekta: они готовят систему под
установку и всё, что вокруг неё.

| Делается | Не делается |
|---|---|
| Базовая настройка ОС, время, локали, лимиты, sysctl | Установка docker и стека Nekta |
| Разметка и монтирование диска хранения в `/nekta` | Настройка самого приложения Nekta |
| RAID1 и хранилище копий на backup-сервере | Настройка приборов учёта и шлюзов |
| Межсетевой экран под порты Nekta | Выпуск TLS-сертификатов |
| Проверка соответствия железа профилю 10 000 устройств | |
| Резервное копирование с ротацией и контролем свежести | |
| ИБП: драйвер, мониторинг, корректное выключение обеих машин | |

## Окружение

### NixOS и Nix

В репозитории есть `flake.nix` с devShell: ansible со всеми коллекциями,
ansible-lint, yamllint, shellcheck, sshpass (нужен вендору, он работает по
паролю) и mkpasswd — ставить ничего не требуется.

```bash
nix develop            # войти в окружение
nk-help                # список команд
```

С [direnv](https://direnv.net/) окружение поднимается само при переходе в
каталог:

```bash
direnv allow
```

Команды-обёртки принимают любые аргументы `ansible-playbook`:

| Команда | Что делает |
|---|---|
| `nk-help` | список всех команд |
| `nk-bootstrap` | python3 на «чистой» ОС (с `-k -K`) |
| `nk-preflight` | проверка железа и сети, ничего не меняет |
| `nk-check` | прогон `site.yml` в режиме `--check --diff` |
| `nk-site` | настроить оба сервера |
| `nk-nekta` / `nk-backup` / `nk-ups` | по отдельности |
| `nk-backup-run` | снять резервную копию сейчас |
| `nk-status` | свежесть копий и свободное место |
| `nk-ups-test` | состояние ИБП |
| `nk-facts` | характеристики серверов |
| `nk-lint` / `nk-syntax` | проверки перед коммитом |
| `nk-vault` | правка файла секретов |

```bash
nk-nekta --tags storage --limit nekta-01 --check
nk-site --ask-vault-pass
```

Пакет `ansible` из nixpkgs уже содержит `community.general` и `ansible.posix`,
поэтому `ansible-galaxy` запускать не нужно.

### Без Nix

```bash
pip install ansible ansible-lint yamllint
ansible-galaxy collection install -r requirements.yml
```

Дальше — цели `make` (`make help`), они повторяют команды `nk-*`.

## Быстрый старт

```bash
# 1. Зависимости — см. раздел выше (nix develop либо pip)

# 2. Инвентарь: адреса, диски, почта
$EDITOR inventory/hosts.yml
$EDITOR inventory/host_vars/nekta-01.yml     # реальные /dev/disk/by-id/...
$EDITOR inventory/host_vars/backup-01.yml

# 3. Секреты (пароли NUT, SMTP, borg)
mkdir -p inventory/group_vars/all
cp inventory/group_vars/all.yml inventory/group_vars/all/main.yml
rm inventory/group_vars/all.yml
cp inventory/vault.yml.example inventory/group_vars/all/vault.yml
ansible-vault encrypt inventory/group_vars/all/vault.yml

# 4. Первый прогон на «чистой» ОС (только python3)
nk-bootstrap -k -K

# 5. Проверка железа и сети — ничего не меняет
nk-preflight --ask-vault-pass

# 6. Настройка
nk-site --ask-vault-pass
```

Без Nix те же шаги — через `make bootstrap`, `make preflight`, `make site`
(`make help` покажет все цели).

## Порядок запуска и почему он такой

`site.yml` выполняет плейбуки строго в этом порядке:

1. **`backup.yml`** — на сервере копий генерируется ключ SSH;
2. **`nekta.yml`** — этот ключ прописывается агенту `nekta-backup`, поэтому
   сервер копий сразу может забирать данные;
3. **`ups.yml`** — обе машины уже доступны, и клиент NUT может проверить связь
   с сервером ИБП.

Отдельные части запускаются самостоятельно, а внутри — по тегам:

```bash
ansible-playbook playbooks/nekta.yml  --tags storage,firewall
ansible-playbook playbooks/backup.yml --tags backup
ansible-playbook playbooks/ups.yml
```

## Эксплуатация

```bash
ansible-playbook playbooks/backup-run.yml                        # снять копию вручную
ansible-playbook playbooks/backup-run.yml -e backup_dry_run=true # проверочный прогон
ansible-playbook playbooks/ups-test.yml                          # состояние ИБП

# на backup-сервере
nekta-backup-status                     # свежесть копий, свободное место
nekta-restore list nekta-01             # доступные снимки
nekta-restore extract nekta-01 2026-09-01_013000 /nekta/backup-dumps/latest /tmp/dump
```

## Документация

| Файл | О чём |
|---|---|
| [docs/01-sizing-10k.md](docs/01-sizing-10k.md) | Требования к железу, расчёт объёма дисков |
| [docs/02-storage.md](docs/02-storage.md) | Диски, RAID1, защита от переформатирования |
| [docs/03-ups-nut.md](docs/03-ups-nut.md) | ИБП: подбор драйвера, проверка, порядок выключения |
| [docs/04-network-ports.md](docs/04-network-ports.md) | Порты Nekta, исходящий доступ, обход ufw докером |
| [docs/05-backup-restore.md](docs/05-backup-restore.md) | Как устроены копии и как восстанавливаться |
| [docs/06-handover.md](docs/06-handover.md) | Что передать в техподдержку Nekta |

## Структура

```
inventory/          адреса, профиль нагрузки, диски, секреты
playbooks/          site, nekta, backup, ups, preflight, эксплуатация
roles/
  common/           база ОС: время, локали, лимиты, SSH, почта, S.M.A.R.T.
  storage/          RAID1, файловые системы, монтирование
  firewall/         ufw + правила DOCKER-USER
  nut/              ИБП: драйвер, upsd, upsmon, upssched, выключение
  nekta_prep/       проверки профиля, /nekta, daemon.json, агент бэкапа
  backup_server/    pull-копирование, ротация, контроль, восстановление
docs/               эксплуатационная документация
```

## Проверки перед коммитом

```bash
nk-lint          # или: make lint    — ansible-lint (профиль production), yamllint, shellcheck
nk-syntax        # или: make syntax  — разбор всех плейбуков
```

Те же проверки выполняет GitHub Actions (`.github/workflows/lint.yml`).
