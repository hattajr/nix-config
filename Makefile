.PHONY: multipass-validation test test-interactive test-interactive-new

test:
	@./tests/validate-flake.sh
	@./tests/bootstrap/test-bootstrap.sh
	@./tests/identity/test-identity.sh
	@./tests/pi/test-patch-pi-package.sh
	@./tests/pi/test-update-pi.sh
	@./tests/pi/test-update-pins.sh
	@./tests/pi/test-model-presets.sh
	@"$${NODE:-node}" --experimental-strip-types --test tests/pi/model-presets.test.mjs
	@./tests/skills/test-skills.sh
	@./tests/bro/test-bro.sh
	@./tests/proton-pass/test-pi-wrapper.sh
	@./tests/proton-pass/test-session-wrapper.sh
	@./tests/proton-pass/test-setup.sh
	@./tests/shadow/test-shadow.sh

multipass-validation:
	@./tests/run-multipass.sh

test-interactive:
	@./tests/run-multipass-interactive.sh

test-interactive-new:
	@./tests/run-multipass-interactive.sh --fresh
