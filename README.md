# positron-remote-sh

Проекты в отдельных контейнерах на командном сервере, открываемые из Positron по SSH, — как
[positron-remote](https://github.com/fnkc-stats/positron-remote), но только на SSH, bash и Docker, без Node.js на
сервере и у аналитиков.

Статус: план и основа кода (структура каталогов, `server/lib/core.sh`, тесты на bats с подменными `docker`/`ssh`/`gh`;
как добавлять запросы, команды и тесты — [docs/conventions.md](docs/conventions.md)). План — [docs/plan.md](docs/plan.md); поведение, которое нужно сохранить, —
[reference/](reference/) (замороженные документы positron-remote).

Проверки перед коммитом: `./lint.sh --install-hook`.
