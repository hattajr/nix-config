.PHONY: docker-validation test-interactive

docker-validation:
	@./tests/run-docker.sh

test-interactive:
	@./tests/run-interactive.sh
