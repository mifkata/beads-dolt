SYNC_INTERVAL ?= 3600
export SYNC_INTERVAL

DB ?=

.PHONY: start stop build rebuild restart shell mysql logs test databases issues stats purge db-rename

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

test:
	@ok=0; \
	for i in 1 2 3 4 5 6 7 8 9 10; do \
		if docker compose exec -T dolt mysql --protocol=TCP -h 127.0.0.1 -P 3307 -u root -N --batch -e "SHOW DATABASES" >/dev/null 2>&1; then \
			ok=1; \
			break; \
		fi; \
		sleep 1; \
	done; \
	if [ "$$ok" -eq 1 ]; then \
		printf '%s\n' '✅ Dolt is serving on port 3307'; \
	else \
		printf '%s\n' '❌ Dolt is not serving on port 3307' >&2; \
		exit 1; \
	fi

databases:
	@./bin/databases.sh list

issues:
	@./bin/databases.sh issues $(DB)

stats:
	@./bin/databases.sh stats

purge:
	@./bin/databases.sh purge $(DB)

db-rename:
	@./bin/databases.sh rename
