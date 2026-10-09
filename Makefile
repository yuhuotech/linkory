.PHONY: server-test server-run up down
server-test:
	cd linkory-server && (set -a; [ -f .env.local ] && . ./.env.local; set +a; go vet ./... && go test ./...)
server-run:
	cd linkory-server && set -a && . ./.env.local && set +a && go run ./cmd/linkory-server
up:
	docker compose -f deploy/docker-compose.yml up -d --build
down:
	docker compose -f deploy/docker-compose.yml down

.PHONY: app-test app-macos-dmg
app-test:
	cd linkory-app && flutter analyze && flutter test
app-macos-dmg:
	tools/package_macos.sh
