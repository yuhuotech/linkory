.PHONY: server-test server-run up down
server-test:
	cd linkory-server && go vet ./... && go test ./...
server-run:
	cd linkory-server && go run ./cmd/linkory-server
up:
	docker compose -f deploy/docker-compose.yml up -d --build
down:
	docker compose -f deploy/docker-compose.yml down
