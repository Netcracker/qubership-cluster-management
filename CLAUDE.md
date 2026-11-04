# CLAUDE.md — рабочий контекст для Claude

Обновлять по ходу работы: постановка, решения, вопросы-ответы, прогресс. Источник правды о коде — сам код;
здесь только то, что из кода не видно (почему так, что решено, что дальше).

## Кто есть кто
- Boris L в MoM = пользователь (Boris Lavrishchev). Владелец action items 2 (SOPS + SSH, вместе с Pavel A),
  3 (Kubemarine через jump host), 4 (CI/CD, раннеры), 6 (логи/отладка, вместе с Pavel A).
- Документ к встрече 16.11.2026: https://claude.ai/artifact/VVMsMjwV5JaGkmMD5aR796 (Claude Docs, doc id
  e6b5918c-3be2-433f-994c-2ada753b84fd). Держать в синхроне с решениями ниже.

## Постановка (MoM + уточнения Boris, 2026-11-04)
1. Бандл: манифест компонентов (Nexus, Argo CD, Headlamp, Istio, Kiali, MinIO, артефакты Kubemarine) с версиями
   и исходными источниками.
2. Деплой: 5.1 инфраструктура (сети, роли) → 5.2 параллельно {Nexus VM + установка + загрузка бандла;
   VM нод + jump host} → 5.3 ждём VM и наполненный Nexus → 5.4 cluster.yaml → 5.5 kubemarine install →
   5.6 helmfile.
3. Nexus всегда на отдельной VM (и для managed, и для VM-схемы). В VM-схеме он ЕДИНСТВЕННЫЙ источник:
   из интернета ничего не скачивается.
4. Секреты (SSH-ключи, облачные креды) — в репозитории под SOPS, несколько ключей; источник ключа
   переключается просто: локальный файл / переменная CI / облачный secret manager.
5. MoM: 3 шага Terraform — (1) jump host + Nexus, (2) Kubemarine, (3) удалить jump host.

## Ответы Boris (2026-11-04)
1. Бандл попадает в Nexus с машины оператора через jump host.
2. Helmfile запускается на машине оператора, там же, где atmos (`atmos helmfile ... -s`).
3. Изолируем только VM-схему. Managed (EKS/AKS/GKE) пока берут чарты и образы из интернета.

## Принятые решения
- Компоненты VM-схемы (на каждое облако aws/azure/gcp):
  - `<cloud>/network`: у подсети флаг `public` (AWS: без маршрута в IGW; Azure: `default_outbound_access_enabled`;
    GCP: изоляция = VM без external IP). Выход `vpc_cidr`.
  - `<cloud>/vms` — общий модуль «группа VM»: `name`, `vms` (map: roles, instance_type, subnet, volume_size),
    `public`, `ports`, `allowed_cidrs`, `ssh_public_key`. Выход `vms` = [{name, roles, address, internal_address}].
    В стеке три экземпляра: `jump-host` (public, 22 от admin CIDR), `nexus` (private, 22/8081/8082 от VPC CIDR),
    `vms` (ноды, private, 22/80/443/6443 от VPC CIDR). Без ссылок между SG разных компонентов → можно
    применять параллельно и удалять jump-host отдельно.
  - `kubemarine` (облаконезависимый): строит cluster.yaml из выходов `vms`, `jump-host`, `nexus` и запускает
    `kubemarine install` на машине оператора (tools-образ) через jump host как `gateway_nodes`.
- Шаг (3) MoM «удалить jump host переменной» заменён на `atmos terraform destroy jump-host` (отдельный компонент).
- SOPS: `secrets/<stack>.yaml`, ключи = имена env-переменных (`TF_VAR_ssh_public_key`, `TF_VAR_ssh_private_key`,
  `NEXUS_ADMIN_PASSWORD`, облачные креды вроде `AWS_ACCESS_KEY_ID`, `ARM_CLIENT_SECRET`). Запуск:
  `sops exec-env secrets/<stack>.yaml '<atmos ...>'` — секреты не попадают ни в tfvars, ни в state.
  Источник ключа age: `SOPS_AGE_KEY_FILE` (по умолчанию `local/age.key`, gitignored), `SOPS_AGE_KEY` (CI),
  `SOPS_AGE_KEY_CMD` (команда, читающая ключ из облачного secret manager); плюс KMS-ключи в `.sops.yaml`.
  Вместо OpenPGP из MoM — age (PGP можно добавить вторым ключом).
- Доступ оператора в приватную сеть: SOCKS-туннель через jump host (`local/lab.sh tunnel`). Helmfile получает
  `HTTP(S)_PROXY=socks5://127.0.0.1:<port>`, kubeconfig — `proxy-url`, server = внутренний IP control-plane.
- Nexus: ставится по SSH из бандла (tarball через ProxyJump), `nexus.security.randompassword=false`, затем пароль
  admin из SOPS. Репозитории: один raw hosted `bundle` (thirdparties-файлы, плоский apt-репозиторий, Helm-чарты
  с index.yaml) и один docker hosted `images` на порту 8082, анонимное чтение.
- Образы: Kubemarine-образы лежат в Nexus без имени реестра (`kube-apiserver`, `calico/node`), т.к. Kubemarine
  подставляет `registry.mirror_registry`. Образы приложений — как `<исходный реестр>/<путь>`, containerd-зеркала
  на docker.io/quay.io/ghcr.io/registry.k8s.io с `override_path`.
- Kubemarine 0.55.0: по умолчанию K8s v1.34.2, calico v3.32.0, nginx-ingress v1.16.0 (ghcr.io/netcracker).
  Нужен containerd 2.2.* → он есть в Ubuntu 24.04 (проверено), поэтому образ нод — Ubuntu 24.04.
- Azure дропает IPIP → Calico VXLAN (в `catalog/azure/vms.yaml`).
- Инструменты в tools-образе: sops 3.13.3, age 1.3.2, crane 0.22.1 (+ kubemarine 0.55.0 в venv).

## Факты о среде (проверено)
- Floci ЗАПУСКАЕТ EC2 как контейнеры с user_data (так работает Nexus в AWS-лабе). Kubemarine всё равно нужны
  настоящие VM (systemd, модули ядра). Фраза в docs «Floci не запускает VM» — неверна, исправить.
- Atmos не передаёт имя стека в shell-шаги workflow → workflow пишутся на конкретный стек.
- Atmos находит стеки только в `stacks/customers/**` → `secrets/`, `bundle/` вне стеков.
- azurerm проверяет формат ID даже с mock-провайдером → в моках нужны настоящие по форме ID.
- Сравнение списков в tftest строгое по типу → сравнивать через `jsonencode`.

## Стоимость прогона (цены на 2026-11-04, pay-as-you-go USD, в документе к встрече)
- Azure northeurope: ≈ $1.29/ч (5×D4s_v5 $0.214, D2s_v5 $0.107, B2s $0.045, StandardSSD E6×5/E15/E4, IP $0.005).
- AWS us-east-1: ≈ $1.13/ч (5×m5.xlarge $0.192, m5.large $0.096, t3.small $0.0208, gp3 $0.08/ГБ-мес × 470 ГБ, IPv4 $0.005).
- Минимальный стенд 1 CP + 1 worker: Azure ≈ $0.63/ч, AWS ≈ $0.54/ч. Источники: Azure Retail Prices API, AWS Price List CSV.

## Бандл и GitHub Releases (2026-11-04)
- Полный бандл: 2.4 ГБ (images 1.6G, nexus 500M, files 318M, apt 74M, charts 0.5M), сборка ~10 мин; build.sh на
  полном манифесте отработал без ошибок.
- Лимиты GitHub: файл ассета < 2 GiB, общий размер и трафик не ограничены, до 1000 ассетов (docs.github.com, about-releases).
- `.github/workflows/bundle.yml`: тег `bundle-*` или workflow_dispatch → tar | split 1900M → 2 части + SHA256SUMS +
  manifest → `gh release create`. Упаковка/распаковка проверены локально (побайтно совпадает), actionlint чистый.
  В GitHub Actions ещё НЕ запускался.

## Открытые вопросы (к встрече 16.11)
- CI-ключ age и GitHub secret `SOPS_AGE_KEY`: кто создаёт, чей ключ ещё добавить в `.sops.yaml`.
- Загрузка Nexus в managed-схеме: тем же загрузчиком, но пока не встроено в workflow.
- Проверка на настоящих облаках: нужен аккаунт/подписка/проект.
- Сохранение логов Kubemarine (dump) в S3 — пункт 6.

## Прогресс (2026-11-04)
- [x] Сети: флаг `public`, выход `vpc_cidr` (aws/azure/gcp)
- [x] `<cloud>/vms` = общая группа VM для aws/azure/gcp (+ тесты с mock-провайдерами)
- [x] kubemarine: local-exec + gateway + Nexus, `mirrored_registries` из манифеста; cluster.yaml проходит JSON-схему
      Kubemarine 0.55.0 (0 ошибок)
- [x] SOPS: `.sops.yaml` (recipient Boris = `local/age.key`), `lab.sh secrets-init` / `with-secrets`;
      проверены источники ключа: файл, `SOPS_AGE_KEY`, `SOPS_AGE_KEY_CMD`
- [x] Бандл: manifest/build/load/nexus-install. Проверено на локальном sonatype/nexus3:3.97.1 + мини-манифест:
      apt install из плоского репо, helm show chart, файл, анонимный pull образов, повторный load — ок
- [x] lab.sh: tunnel, nexus-install, nexus-load, prepare-vms (НЕ запускались против реальных VM)
- [x] Каталоги `catalog/{aws,azure,gcp}/vms.yaml` (jump-host/nexus/vms через abstract vm-group),
      `catalog/kubemarine.yaml`; helmfile-каталоги берут версии/репо из манифеста через `!include`;
      helmfile url = `{{ .Values | get "nexus_charts" .Values.chart_repository }}`
- [x] Пример стека `customers/customer1/aws/vm.yaml.example`, workflow `customers/customer1/aws-vm.yaml`
      (deploy-vm, deploy-nexus, deploy-apps, open-access, close-access, destroy-vm)
- [x] Docs: `docs/vm-installation.md` (основной гайд), architecture/getting-started/README обновлены
- [x] Документ к встрече: контекст, процесс (схема), решения, SOPS, бандл, вопросы
- [x] Полный `lab.sh check --init` в tools-образе — ок; статус в документе заполнен, оставлен 1 вопрос-комментарий
      (Kubemarine с машины оператора или на jump host)
- [ ] Реальный прогон в облаке (нужен аккаунт)
- [ ] Примеры стеков/workflow для Azure и GCP (пока только каталоги)
- [ ] Первый запуск workflow Bundle в GitHub Actions

## Как проверять локально
- Модули: `terraform init -backend=false && terraform test` в каталоге модуля (или `lab.sh check --init` в tools-образе).
- Tools-образ: `docker build -t qcm-tools:dev .`; запуск с `-v /var/run/docker.sock:/var/run/docker.sock` для build.sh.
- Nexus-загрузка: `docker run -d --name qcm-nexus --network qcm-test -e NEXUS_SECURITY_RANDOMPASSWORD=false
  sonatype/nexus3:3.97.1`, затем build.sh/load.sh в tools-контейнере в той же сети (BUNDLE_MANIFEST = мини-манифест).
- Схема Kubemarine: jsonschema + `kubemarine/resources/schemas/cluster.json` из venv tools-образа.
