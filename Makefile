SYNC_INTERVAL ?= 60
export SYNC_INTERVAL

DB ?=

.PHONY: start stop build rebuild restart shell mysql logs databases issues stats purge

start:
	docker compose up -d

stop:
	docker compose down

build:
	docker compose build

rebuild:
	docker compose build --no-cache
	$(MAKE) start

restart: stop start

shell:
	docker compose exec dolt bash

mysql:
	docker compose exec dolt mysql -h 127.0.0.1 -P 3307 -u root

logs:
	docker compose exec dolt tail -f /tmp/dolt-sync.log

databases:
	@./bin/databases.sh list

issues:
	@./bin/databases.sh issues $(DB)

stats:
	@./bin/databases.sh stats

purge:
	@./bin/databases.sh purge $(DB)
