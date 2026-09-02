.PHONY: multipass-validation test test-interactive test-interactive-new

test:
	@./tests/validate-flake.sh
	@./tests/bootstrap/test-bootstrap.sh
	@./tests/identity/test-identity.sh
	@./tests/pi/test-patch-pi-package.sh
	@./tests/bro/test-bro.sh
	@./tests/proton-pass/test-pi-wrapper.sh
	@./tests/proton-pass/test-session-wrapper.sh
	@./tests/proton-pass/test-setup.sh

multipass-validation:
	@./tests/run-multipass.sh

test-interactive:
	@./tests/run-multipass-interactive.sh

test-interactive-new:
	@./tests/run-multipass-interactive.sh --fresh
