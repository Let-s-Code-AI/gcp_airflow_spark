# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Infrastruktura kursu analityki danych: klaster Kubernetes stawiany przez `kubeadm` na trzech VM-kach GCE (Terraform), a na nim Apache Airflow (KubernetesExecutor), JupyterHub i stos monitoringu. Komentarze, komunikaty w skryptach, nazwy (`analitycy`, `analityk01`) i dokumentacja są po polsku — trzymaj się tego.

## Polecenia

W repo nie ma testów, CI ani konfiguracji lintera. Kontrole, które da się uruchomić bez klastra:

```bash
bash -n scripts/*.sh                          # składnia
shellcheck scripts/*.sh                       # obecnie zgłasza ostrzeżenia
terraform fmt -check -recursive terraform/    # obecnie zgłasza vms.tf; bez -check, żeby naprawić
```

Deploy i sprzątanie:

```bash
./scripts/deploy.sh <PROJECT_ID>     # terraform apply + czekanie na bootstrap (~8-12 min)
./scripts/destroy.sh <PROJECT_ID>    # interaktywne: trzeba wpisać 'kasuj'
```

- `deploy.sh` jest zablokowany dla Claude w `.claude/settings.json` (`permissions.deny`, lista w sekcji „Blokady uprawnień Claude”). Uruchamia go użytkownik. Nie obchodź blokady przez ręczne `terraform apply`.
- `deploy.sh` wymaga pliku `.env` w katalogu głównym (gitignorowany) ze zmiennymi: `AIRFLOW_ADMIN_PASSWORD`, `AIRFLOW_ANALYST_PASSWORD`, `JUPYTERHUB_ADMIN_PASSWORD`, `JUPYTERHUB_ANALYST_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `REGION`, `ZONE`, `TF_STATE_BUCKET`, `TF_STATE_PREFIX`.
- Pięć zmiennych z hasłami w `terraform/variables.tf` nie ma wartości domyślnych. Każde ręczne `terraform plan/apply/destroy` wymaga ich przez `-var` albo `TF_VAR_*`, inaczej Terraform pyta interaktywnie. Dotyczy to też `destroy.sh` (przekazuje tylko `project_id`) i przykładów z README.
- State jest zdalny: `backend "gcs" {}` w `main.tf`, bez wartości. Każde `terraform init` wymaga `-backend-config="bucket=..."` i `-backend-config="prefix=..."` (`deploy.sh` bierze je z `TF_STATE_BUCKET`/`TF_STATE_PREFIX`; lint używa `init -backend=false`). Lokalny state migruje administrator (`terraform init -migrate-state`) przed pierwszym uruchomieniem CI.
- Klucz SSH: zmienna `ssh_public_key` (treść klucza; w CI `vars.SSH_PUBLIC_KEY`), a gdy pusta — fallback na plik z `ssh_pub_key_path`.
- `.github/workflows/deploy.yml` (`workflow_dispatch`, `run_apply` i `run_smoke_test` domyślnie wyłączone) robi `init`/`validate`/`plan`, opcjonalnie `apply` i smoke test przez SSH. Projekt i hasła przekazuje jako `TF_VAR_*`; lista zmiennych i sekretów jest w README.

Praca z działającym klastrem odbywa się z mastera — tylko on ma publiczne IP:

```bash
ssh ubuntu@"$(terraform -chdir=terraform output -raw master_external_ip)"
tail -f /var/log/master-init.log      # postęp bootstrapu; na workerach /var/log/worker-init.log
kubectl get pods -A                   # kubeconfig: /home/ubuntu/.kube/config
```

Przełączanie slotów Airflow (wymaga `kubectl` i `helm` z kontekstem klastra, repo Helm `apache-airflow` oraz katalogu `helm/airflow/` obok skryptu):

```bash
./scripts/green-blue-switch.sh status
./scripts/green-blue-switch.sh deploy blue     # helm install/upgrade release airflow-blue
./scripts/green-blue-switch.sh switch blue     # patch selektora Service airflow-active
./scripts/green-blue-switch.sh rollback
```

## Blokady uprawnień Claude

`.claude/settings.json` jest śledzony w git. `.gitignore` ignoruje `*.json`, więc wyjątek `!.claude/settings.json` jest wymagany. Plik zawiera `permissions.deny`, które blokuje dla Claude:

- **Terraform:** `apply`, `destroy`, `import`, `refresh`, `taint`/`untaint`, `force-unlock`, `state rm|mv|push|replace-provider`, `workspace new|delete`, `-migrate-state`, `-force-copy`.
- **gcloud:** `create`, `delete`, `update`, `patch`, `set`, `unset`, `start`, `stop`, `reset`, `resume`, `suspend`, `resize`, `import`, `deploy`, `enable`, `disable`, `apply`, `move`, `cancel`, `restore`, `rollback`, `upgrade`, `undelete`, `cp`, `mv`, `rm`, `rsync`, `scp` oraz `add-*`, `remove-*`, `set-*`, `attach-*`, `detach-*`.
- **gsutil:** `cp`, `mv`, `rm`, `rsync`, `mb`, `rb`, `compose`, `setmeta`, `defacl`, `retention`, `kms`, `set`, `ch`, `create`, `delete`, `stopchannel`.
- **kubectl:** `apply`, `create`, `delete`, `edit`, `patch`, `replace`, `scale`, `autoscale`, `set`, `label`, `annotate`, `taint`, `cordon`/`uncordon`, `drain`, `expose`, `run`, `exec`, `cp`, `attach`, `debug`, `rollout restart|undo|pause|resume`, `certificate approve|deny`.
- **helm:** `install`, `upgrade`, `uninstall`/`delete`/`del`/`un`, `rollback`, `test`.
- **Skrypty:** `deploy.sh`, `destroy.sh` oraz `green-blue-switch.sh deploy|switch|rollback`, także przez `bash`/`sh`/`source` i w różnych formach ścieżki.
- **Sekrety:** odczyt `./.env`, `**/.env` oraz polecenia kończące się na `.env`.

Polecenia spoza tej listy (np. `kubectl get`, `terraform plan`, `gcloud ... list|describe`) nie są blokowane przez `deny`. Ich dozwolenie zależy od ustawień `allow`/trybu uprawnień. Zmiana listy to zmiana w `settings.json`, nie w `CLAUDE.md`.

## Architektura

### Przepływ bootstrapu

`deploy.sh` → `terraform apply` → VM-ki startują ze skryptami startowymi → cała reszta dzieje się w `scripts/master-init.sh`.

- Terraform tworzy VPC z trzema subnetami w trzech regionach: master w `var.region` (publiczne IP), dwa workery w `europe-west4` i `europe-central2` (bez publicznego IP, wyjście przez Cloud NAT). Regiony workerów są wpisane na sztywno w dwóch miejscach, które muszą się zgadzać: `local.worker_config` w `vms.tf` i `local.worker_regions` w `network.tf`.
- Konfiguracja trafia do VM-ek przez metadane instancji (klucze `tf_*` w `vms.tf`), a skrypty czytają je z serwera metadanych. Nowy parametr przechodzi przez: `variables.tf` → `metadata` w `vms.tf` → `curl "$META/tf_..."` w skrypcie; jeśli pochodzi z `.env`, także `required_vars` i `-var` w `deploy.sh`.
- Master i workery spotykają się przez bucket bootstrapowy: master po `kubeadm init` zapisuje tam `join-command.sh` (oraz `admin.conf`), workery odpytują bucket do 10 minut i dołączają do klastra.
- `deploy.sh` rozpoznaje koniec bootstrapu po napisie `SETUP ZAKOŃCZONY` w `/var/log/master-init.log`. Zmiana tego komunikatu w `master-init.sh` wymaga zmiany w `deploy.sh`.
- Skrypt startowy wykonuje się przy każdym starcie VM i nie jest idempotentny (`kubeadm init`, `kubectl create namespace` pod `set -e`). Zmiana treści `master-init.sh` trafia do metadanych bez odtworzenia VM, więc na działającym klastrze nic nie zmienia — żeby ją przetestować, trzeba postawić klaster od nowa.

### `master-init.sh` jest jedynym źródłem prawdy

Skrypt instaluje kolejno: containerd i kubeadm (K8s 1.29), Calico, local-path-provisioner (domyślny StorageClass), Postgresa (StatefulSet), Airflow (chart 1.15.0, release `airflow-green`), Service `airflow-active`, konta i DAG-i analityków, JupyterHub (chart 3.3.7), kube-prometheus-stack (release `kube-prom`), loki-stack, opentelemetry-collector i reguły alertów. Wszystkie wartości Helm i manifesty są wpisane w skrypcie jako heredoki.

Katalogi `helm/` i `k8s/` **nie są używane przy bootstrapie**. To równoległe kopie, które się rozjechały. Jedyny wyjątek to `helm/airflow/values-{green,blue}.yaml`, czytane przez `green-blue-switch.sh`. Zmiana w `helm/jupyterhub/`, `helm/monitoring/` czy `k8s/` nie ma wpływu na nowy klaster — musi trafić do heredoka w `master-init.sh`.

### DAG-i i izolacja analityków

- Airflow nie pobiera DAG-ów ani z gita, ani z GCS. Czyta `/opt/airflow/dags` — katalog `hostPath` na masterze, montowany do wszystkich komponentów Airflow. Dlatego bootstrap przypina je (łącznie z podami zadań KubernetesExecutora) do mastera przez `nodeSelector`.
- Ten sam katalog jest zamontowany w podach użytkowników JupyterHub jako `/home/jovyan/airflow-dags`, a `~/dags` to symlink do podkatalogu użytkownika. Analityk zapisuje DAG w Jupyterze i od razu widzi go w Airflow.
- Bucket `<project>-<course_name>-dags` przechowuje w `dags/<login>/` **skrypty**, nie DAG-i. Pobiera je i uruchamia DAG `run_script_<login>`, używając tokenu konta serwisowego VM z serwera metadanych.
- Lista `var.analitycy` steruje wszystkim naraz: folderami w GCS (`gcs.tf`), katalogami na masterze, kontem Airflow, rolą o nazwie równej loginowi i plikiem `/opt/airflow/dags/<login>/run_script_<login>.py` z `access_control` ograniczonym do tej roli. Szablon tego DAG-a siedzi jako string Pythona w `master-init.sh` (placeholder `__ANALITYK__`).
- Pliki z `dags/` w repo nie są nigdzie wdrażane automatycznie. `dags/analityk_gcs_runner.py` (DAG `admin_run_script`) to wersja adminowa tego samego szablonu.

### Green-blue

Dwa release'y Helm (`airflow-green`, `airflow-blue`) w tym samym namespace, na tej samej bazie Postgres i tym samym katalogu DAG-ów. Etykieta `labels.slot` z chartu trafia na pody, a Service `airflow-active` (NodePort 30080) wybiera `component=webserver,slot=<aktywny>` — przełączenie to patch selektora. Naraz może działać tylko jeden scheduler: slot standby ma `scheduler.replicas: 0`, a skrypt skaluje schedulery przy przełączeniu. Skrypt znajduje deploymenty po etykietach `slot` i `component`, nie po nazwie release'u.

Ograniczenia, o których trzeba pamiętać:

- Baza metadanych jest wspólna, więc wdrożenie slotu z nowszą wersją Airflow migruje schemat, na którym pracuje też stary slot.
- `green-blue-switch.sh deploy green` nadpisuje release z bootstrapu wartościami z `helm/airflow/values-green.yaml`, które różnią się od bootstrapowych: brak `nodeSelector` na mastera, hasło admina `admin`, dwie repliki webservera, inna wersja Airflow.
- Nazwa `airflow-green-webserver` jest wpisana na sztywno w celu scrape'u OTel Collectora i w `AIRFLOW_HOST` JupyterHuba. Po przełączeniu na blue oba nadal wskazują green.

### Monitoring

OTel Collector (DaemonSet) scrape'uje Airflow i JupyterHub oraz zbiera `kubeletstats`, a metryki wysyła przez remote write do Prometheusa `kube-prom-kube-prometheus-stack-prometheus`. Logi zbiera Promtail i wysyła do Loki. Grafana, Prometheus, JupyterHub i Airflow są wystawione jako NodePorty: 30300, 30090, 30088, 30080.

## Znane niespójności

- README odwołuje się do `.env.example` i `Datasets/` — tych plików nie ma w repo.
- Outputy Terraform `airflow_ui` (`:8080`) i `spark_master_ui` (`:8181`) są nieaktualne; faktyczne adresy to NodePorty powyżej. Firewall nadal otwiera porty z czasów Sparka (7077, 4040, 8181, 15002).
- `stress_test.py` testuje Spark Connect (`sc://…:15002`), którego to repo nie wdraża. Ma wpisane na sztywno IP i sekret.
- `notebooks/airflow_helper.py` jest nieaktualny: wyzwala nieistniejący DAG `analityk_run_script`, zakłada hasło `<login>Pass123!`, domyślnie łączy się z `airflow-webserver` (faktyczna usługa: `airflow-green-webserver`) i wymaga zmiennej `DAG_BUCKET`, której JupyterHub nie ustawia.
- DAG-i biorą nazwę bucketu ze zmiennej Airflow `dag_bucket`, której nic nie ustawia (`master-init.sh` czyta `tf_dag_bucket`, ale go nie używa).
- JupyterHub używa `DummyAuthenticator`: wszyscy, łącznie z adminem, logują się hasłem `JUPYTERHUB_ANALYST_PASSWORD`. `JUPYTERHUB_ADMIN_PASSWORD` jest wymagane, ale nieużywane. Allowlista `analityk01..16` jest wpisana na sztywno i nie wynika z `var.analitycy`.
- Wersje Airflow się rozjeżdżają: README i nieużywana zmienna `AIRFLOW_VERSION` mówią 2.9.1, `values-green.yaml` 2.9.2, `values-blue.yaml` 2.10.2.
- Końcowe logi `master-init.sh` wypisują stare, wpisane na sztywno hasła zamiast tych z `.env`. Stare hasło Grafany jest też w `helm/monitoring/kube-prometheus-values.yaml`. Nie kopiuj ich i nie dodawaj kolejnych.
- Role projektowe konta serwisowego VM są zakomentowane w `vms.tf` (nadawane ręcznie przez `gcloud`); Terraform nadaje tylko `objectAdmin` na obu bucketach.
- README opisuje etykietowanie node'ów w `worker-join.sh` — skrypt tego nie robi.
- `.gitignore` ignoruje `*.json` (wyjątki: `helm/**/*.json`, `.claude/settings.json`). Inne pliki JSON wymagają `git add -f`.

## Commity

Repo stosuje [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Każdy komunikat commita ma format:

```
<type>(<opcjonalny scope>): <krótki opis>

<opcjonalna treść — co i dlaczego>

<opcjonalna stopka, np. BREAKING CHANGE: ...>
```

Dozwolone typy:

- `feat` — nowa funkcjonalność
- `fix` — poprawka błędu
- `docs` — tylko dokumentacja (np. README)
- `refactor` — zmiana kodu bez zmiany zachowania
- `style` — formatowanie, poprawki lintera
- `test` — testy
- `ci` — pipeline'y i automatyzacja
- `build` — zależności, narzędzia budowania
- `chore` — pozostałe porządki
- `perf` — poprawa wydajności
- `revert` — wycofanie commita

Zasady:

- Komunikaty commitów pisz po angielsku.
- Opis w trybie rozkazującym, małą literą, bez kropki na końcu, do około 72 znaków.
- Scope jest opcjonalny i nazywa obszar repo: `terraform`, `scripts`, `helm`, `k8s`, `dags`, `notebooks`.
- Zmiana łamiąca kompatybilność: `!` po typie lub scope (`feat(terraform)!: ...`) albo stopka `BREAKING CHANGE: ...`.
- Jeden commit to jedna logiczna zmiana; nie mieszaj typów w jednym commicie.

Przykłady:

```
feat(terraform): add firewall rule for airflow nodeport
fix(scripts): set dag_bucket airflow variable during bootstrap
docs: add CLAUDE.md with project context
refactor(helm): align green values with bootstrap config
chore: ignore local terraform plan files
```

Tytuły pull requestów mają ten sam format.
