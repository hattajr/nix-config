.PHONY: multipass-validation test test-interactive

test:
	@./tests/bootstrap/test-bootstrap.sh
	@./tests/identity/test-identity.sh
	@./tests/bro/test-bro.sh
	@./tests/proton-pass/test-pi-wrapper.sh
	@./tests/proton-pass/test-session-wrapper.sh
	@./tests/proton-pass/test-setup.sh

multipass-validation:
	@./tests/run-multipass.sh

test-interactive:
	@./tests/run-multipass-interactive.sh
