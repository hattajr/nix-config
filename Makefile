.PHONY: incus-validation incus-alice-validation test test-interactive

test:
	@./tests/bootstrap/test-bootstrap.sh
	@./tests/migration/test-migrate-chezmoi.sh
	@./tests/identity/test-identity.sh
	@./tests/bro/test-bro.sh
	@./tests/proton-pass/test-pi-wrapper.sh
	@./tests/proton-pass/test-session-wrapper.sh
	@./tests/proton-pass/test-setup.sh

incus-validation:
	@./tests/run-incus.sh

incus-alice-validation:
	@./tests/run-incus-alice.sh

test-interactive:
	@./tests/run-interactive.sh
