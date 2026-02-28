SYNC_SCHEDULE ?= 0 * * * *
export SYNC_SCHEDULE

.PHONY: start stop build rebuild restart shell mysql logs

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
