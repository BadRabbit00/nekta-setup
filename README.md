# Ansible: подготовка серверов под Nekta Server

Плейбуки готовят два сервера к установке программного комплекса **Nekta
Server** в профиле **до 10 000 устройств** и настраивают ИБП с USB.

Объём работ ограничен документацией вендора: делается ровно то, что
предписано в «Подготовке к установке» и «Системных требованиях», плюс ИБП по
требованию заказчика. Границы и обоснование каждого действия —
**[docs/00-scope.md](docs/00-scope.md)**.

```
                    ~~~ электросеть ~~~
                            │
                        ┌───┴────┐
                        │  ИБП   │
                        └─┬────┬─┘
              питание     │    │  USB
        ┌─────────────────┘    └──────────────┐
        │                                     │
┌───────┴────────────┐                ┌───────┴──────────────┐
│  nekta-01          │  состояние ИБП │  backup-01           │
│  Nekta Server      │───────────────►│  RAID1 из 2 x HDD    │
│  диск 2 -> /nekta  │   порт 3493    │  NUT: netclient      │
│  порты 80/81/443…  │                │                      │
│  NUT: netserver    │                │                      │
└────────────────────┘                └──────────────────────┘
```

## Что делается

| Сервер приложения | Сервер резервного копирования |
|---|---|
| Проверка процессора, ОЗУ, дисков, сети по профилю 10 000 устройств | Проверка процессора, ОЗУ, дисков |
| Расчёт требуемого объёма `/nekta` по методике вендора | Проверка правила «объём копий ≥ 3× объёма защищаемых дисков» |
| Проверка исходящего доступа к ресурсам Nekta | |
| Монтирование диска 2 в `/nekta` | RAID1 из двух HDD и его монтирование |
| Открытие портов Nekta в ufw | |
| Сбор сведений для техподдержки | |

На обоих серверах — настройка ИБП: драйвер, мониторинг, корректное
выключение (сервер копий гасится первым).

## Чего не делается

**Nekta Server не устанавливается** — его ставит вендор по SSH, и
документация требует передавать «чистую» ОС без дополнительных компонентов.

**Программное обеспечение резервного копирования не настраивается.** В
документации Nekta для сервера копий описано только железо: процессор, ОЗУ,
RAID1, объём, скорость сети. Процедуры копирования там нет. Что снимать и чем
— выясните в техподдержке (support@nekta.tech); до тех пор копии не
снимаются, и об этом лучше знать заранее.

**Настройка ОС не выполняется** — ни времени, ни лимитов, ни sysctl, ни
автообновлений, ни S.M.A.R.T., ни усиления SSH. Всё это можно добавить, но
отдельным решением: см. [docs/00-scope.md](docs/00-scope.md).

## Окружение

### NixOS и Nix

В репозитории есть `flake.nix` с devShell: ansible со всеми коллекциями,
ansible-lint, yamllint, shellcheck и sshpass (вендор подключается по паролю).

```bash
nix develop            # войти в окружение
nk-help                # список команд
```

С [direnv](https://direnv.net/) окружение поднимается само:

```bash
direnv allow
```

| Команда | Что делает |
|---|---|
| `nk-help` | список всех команд |
| `nk-bootstrap` | python3 на «чистой» ОС (с `-k -K`) |
| `nk-preflight` | проверка железа и сети, ничего не меняет |
| `nk-check` | прогон `site.yml` в режиме `--check --diff` |
| `nk-site` | подготовить оба сервера |
| `nk-nekta` / `nk-backup` | по отдельности |
| `nk-ups` | настроить ИБП (после установки Nekta вендором) |
| `nk-ups-test` | состояние ИБП |
| `nk-facts` | характеристики серверов |
| `nk-lint` / `nk-syntax` | проверки перед коммитом |
| `nk-vault` | правка файла секретов |

Аргументы уходят в `ansible-playbook` как есть:

```bash
nk-nekta --tags storage --limit nekta-01 --check
```

Пакет `ansible` из nixpkgs уже содержит `community.general` и `ansible.posix`,
поэтому `ansible-galaxy` запускать не нужно.

### Без Nix

```bash
pip install ansible ansible-lint yamllint
ansible-galaxy collection install -r requirements.yml
```

Дальше — цели `make` (`make help`), они повторяют команды `nk-*`.

## Порядок работ

```bash
# 1. Инвентарь: адреса и реальные диски
$EDITOR inventory/hosts.yml
$EDITOR inventory/host_vars/nekta-01.yml     # /dev/disk/by-id/... вместо CHANGE_ME
$EDITOR inventory/host_vars/backup-01.yml

# 2. Секреты — нужны только для ИБП
mkdir -p inventory/group_vars/all
mv inventory/group_vars/all.yml inventory/group_vars/all/main.yml
cp inventory/vault.yml.example inventory/group_vars/all/vault.yml
ansible-vault encrypt inventory/group_vars/all/vault.yml

# 3. Проверка железа и сети — ничего не меняет
nk-preflight

# 4. Подготовка обоих серверов
nk-site --ask-vault-pass

# 5. Передать доступ вендору, дождаться установки Nekta Server
#    docs/05-handover.md, сведения — в /etc/nekta/install-info

# 6. Настроить ИБП (после установки: до неё ОС должна быть «чистой»)
nk-ups --ask-vault-pass
```

Шаг 6 намеренно вынесен из `site.yml`: NUT — это дополнительные пакеты.

## Документация

| Файл | О чём |
|---|---|
| [docs/00-scope.md](docs/00-scope.md) | **Границы работ: что делается, чего нет и почему** |
| [docs/01-sizing.md](docs/01-sizing.md) | Требования к железу, расчёт объёма дисков |
| [docs/02-storage.md](docs/02-storage.md) | Диски, RAID1, защита от переформатирования |
| [docs/03-ups-nut.md](docs/03-ups-nut.md) | ИБП: подбор драйвера, проверка, порядок выключения |
| [docs/04-network-ports.md](docs/04-network-ports.md) | Порты Nekta, исходящий доступ, доступ вендора |
| [docs/05-handover.md](docs/05-handover.md) | Что передать в техподдержку Nekta |

## Структура

```
inventory/          адреса, профиль нагрузки, диски, секреты
playbooks/          site, nekta, backup, ups, preflight, bootstrap
roles/
  requirements/     проверка системных требований, расчёт объёма, доступ в сеть
  storage/          RAID1, файловые системы, монтирование /nekta и /backup
  firewall/         порты из документации Nekta
  handover/         сведения для передачи в техподдержку
  nut/              ИБП: драйвер, upsd, upsmon, выключение
docs/               документация
```

## Проверки перед коммитом

```bash
nk-lint          # или: make lint    — ansible-lint (профиль production), yamllint, shellcheck
nk-syntax        # или: make syntax  — разбор всех плейбуков
```

Те же проверки выполняет GitHub Actions (`.github/workflows/lint.yml`).
