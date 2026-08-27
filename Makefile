.PHONY: docker-validation test test-interactive

test:
	@./tests/bootstrap/test-bootstrap.sh
	@./tests/proton-pass/test-pi-wrapper.sh
	@./tests/proton-pass/test-session-wrapper.sh
	@./tests/proton-pass/test-setup.sh

docker-validation:
	@./tests/run-docker.sh

test-interactive:
	@./tests/run-interactive.sh
