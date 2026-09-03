{
  description = "Ansible-площадка Nekta: сервер приложения и сервер резервного копирования";

  inputs = {
    # При желании закрепиться на релизе замените на nixos-25.11 и выполните
    # nix flake update.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs:
        let
          # Пакет ansible из nixpkgs — это полная сборка вместе с коллекциями
          # community.general и ansible.posix, поэтому ansible-galaxy запускать
          # не нужно: галактика в закрытых сетях всё равно недоступна.
          ansibleFull = pkgs.ansible;

          # Обёртки вместо алиасов: работают и в скриптах, и в неинтерактивной
          # оболочке, и видны в PATH.
          mk = name: text: pkgs.writeShellApplication {
            inherit name text;
            runtimeInputs = [ ansibleFull ];
          };

          play = name: args: mk name ''
            exec ansible-playbook ${args} "$@"
          '';

          cmds = [
            (play "nk-preflight" "playbooks/preflight.yml")
            (play "nk-site" "playbooks/site.yml")
            (play "nk-nekta" "playbooks/nekta.yml")
            (play "nk-backup" "playbooks/backup.yml")
            (play "nk-ups" "playbooks/ups.yml")
            (play "nk-bootstrap" "playbooks/bootstrap.yml")
            (play "nk-backup-run" "playbooks/backup-run.yml")
            (play "nk-ups-test" "playbooks/ups-test.yml")

            (mk "nk-check" ''
              exec ansible-playbook playbooks/site.yml --check --diff "$@"
            '')

            (mk "nk-status" ''
              exec ansible backup --become --args /usr/local/sbin/nekta-backup-status "$@"
            '')

            (mk "nk-facts" ''
              exec ansible all --become --module-name setup \
                --args 'filter=ansible_processor*,ansible_memtotal_mb,ansible_mounts' "$@"
            '')

            (pkgs.writeShellApplication {
              name = "nk-lint";
              runtimeInputs = with pkgs; [ ansible-lint yamllint shellcheck bash ];
              text = ''
                set -e
                echo "== yamllint";     yamllint .
                echo "== ansible-lint"; ansible-lint
                echo "== shellcheck";   shellcheck roles/backup_server/files/* roles/firewall/files/*
                echo "== скрипты-шаблоны"
                for f in roles/nut/templates/upssched-cmd.j2 \
                         roles/nut/templates/nekta-ups-shutdown.j2 \
                         roles/nekta_prep/templates/nekta-predump.j2; do
                  sed 's/{%[^%]*%}//g; s/{{[^}]*}}/X/g' "$f" | bash -n -
                  echo "  OK $f"
                done
                echo "Все проверки пройдены"
              '';
            })

            (pkgs.writeShellApplication {
              name = "nk-syntax";
              runtimeInputs = [ ansibleFull ];
              text = ''
                for pb in playbooks/*.yml; do
                  echo "== $pb"
                  ansible-playbook --syntax-check "$pb" > /dev/null
                done
                echo "Синтаксис в порядке"
              '';
            })

            (pkgs.writeShellApplication {
              name = "nk-vault";
              runtimeInputs = [ ansibleFull ];
              text = ''
                # Правка зашифрованного файла секретов.
                exec ansible-vault edit inventory/group_vars/all/vault.yml "$@"
              '';
            })

            (pkgs.writeShellApplication {
              name = "nk-help";
              text = ''
                cat <<'HELP'
                Команды площадки Nekta

                  Подготовка
                    nk-bootstrap     python3 на «чистой» ОС (запускать с -k -K)
                    nk-preflight     проверка железа и сети, ничего не меняет
                    nk-check         прогон site.yml в режиме --check --diff

                  Настройка
                    nk-site          оба сервера целиком
                    nk-nekta         только сервер приложения
                    nk-backup        только сервер резервного копирования
                    nk-ups           ИБП на обоих серверах

                  Эксплуатация
                    nk-backup-run    снять резервную копию сейчас
                    nk-status        свежесть копий и свободное место
                    nk-ups-test      состояние ИБП
                    nk-facts         характеристики серверов

                  Разработка
                    nk-lint          ansible-lint + yamllint + shellcheck
                    nk-syntax        разбор всех плейбуков
                    nk-vault         правка файла секретов

                Аргументы уходят в ansible-playbook как есть:
                    nk-nekta --tags storage --limit nekta-01 --check
                    nk-site --ask-vault-pass
                HELP
              '';
            })
          ];
        in
        {
          default = pkgs.mkShell {
            name = "nekta-ansible";

            packages = with pkgs; [
              ansibleFull
              ansible-lint
              yamllint
              shellcheck
              sshpass        # для -k: вендор Nekta работает по паролю
              openssh
              mkpasswd       # хеши паролей для common_admin_users
              gnumake
              jq
              git
            ] ++ cmds;

            shellHook = ''
              root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              export ANSIBLE_CONFIG="$root/ansible.cfg"
              export ANSIBLE_LOCALHOST_WARNING=False

              echo "Площадка Nekta: nk-help — список команд, nk-preflight — проверка серверов"
            '';
          };
        });
    };
}
