SHELL := /bin/bash

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Resolve an engine to an ABSOLUTE path. tests/test-cvg-doctor-host.sh narrows
# PATH to system directories to synthesize a missing tool, and a bare name would
# resolve through that narrowed PATH — hiding an engine installed in ~/.local/bin
# (install.sh --global's default) and failing 9 rows for the wrong reason. CI
# already exports absolute paths; this makes a local `make check` match it.
abs_engine = $(if $(filter /%,$(1)),$(1),$(shell command -v $(1) 2>/dev/null || echo $(1)))

# `make bootstrap` assembles the pinned release pairing under .engines/ and
# .venv/. Prefer those when they exist so a bootstrapped clone needs no exports;
# an explicit CVG_* override still wins, and PATH remains the last resort.
BOOTSTRAP_TASKSPEC := $(REPO_ROOT)/.engines/task-spec/bin/taskspec
BOOTSTRAP_SEAMWISE := $(REPO_ROOT)/.venv/bin/seamwise
BOOTSTRAP_PYTHON   := $(REPO_ROOT)/.venv/bin/python

ifeq ($(origin TASKSPEC_BIN),undefined)
TASKSPEC_BIN := $(call abs_engine,$(if $(CVG_TASKSPEC_BIN),$(CVG_TASKSPEC_BIN),$(if $(wildcard $(BOOTSTRAP_TASKSPEC)),$(BOOTSTRAP_TASKSPEC),taskspec)))
endif
ifeq ($(origin SEAMWISE_BIN),undefined)
SEAMWISE_BIN := $(call abs_engine,$(if $(CVG_SEAMWISE_BIN),$(CVG_SEAMWISE_BIN),$(if $(wildcard $(BOOTSTRAP_SEAMWISE)),$(BOOTSTRAP_SEAMWISE),seamwise)))
endif
PYTHON ?= $(if $(wildcard $(BOOTSTRAP_PYTHON)),$(BOOTSTRAP_PYTHON),python3)

# tests/test-compose.sh validates the composition receipt against its JSON Schema
# and needs a python that can import jsonschema. Bare python3 usually cannot, and
# the import failure is reported identically to a real contract violation.
ifeq ($(origin COMPOSE_JSONSCHEMA_PYTHON),undefined)
ifneq ($(wildcard $(BOOTSTRAP_PYTHON)),)
export COMPOSE_JSONSCHEMA_PYTHON := $(BOOTSTRAP_PYTHON)
endif
endif

export CVG_TASKSPEC_BIN := $(TASKSPEC_BIN)
export CVG_SEAMWISE_BIN := $(SEAMWISE_BIN)
export PYTHONDONTWRITEBYTECODE := 1

# Some cvg subcommands re-enter the CLI (`cvg snapshot` shells out to `cvg next`)
# and resolve the engine through PATH rather than CVG_TASKSPEC_BIN. Runtime accepts
# Task-Spec 3.8.x and 3.9.x. CI puts the reviewed 3.8.0 pin on PATH ($GITHUB_PATH);
# this does the same locally so a bootstrapped run matches that pin.
ifneq ($(wildcard $(BOOTSTRAP_TASKSPEC)),)
export PATH := $(dir $(BOOTSTRAP_TASKSPEC)):$(PATH)
endif

.PHONY: bootstrap check check-core check-json check-docs check-composed check-package \
	check-cockpit check-layout check-release-assets check-live-evidence check-memory demo-composed release-check

bootstrap:
	bash scripts/bootstrap.sh

check: check-core check-json check-docs check-composed check-package check-memory

check-core:
	bash skills/task-to-runtime-contract/tests/run-tests.sh
	bash skills/task-specs-to-issues/tests/test-register.sh
	bash tests/test-cvg-snapshot.sh
	bash tests/test-cvg-doctor-plugin.sh
	bash tests/test-cvg-doctor-host.sh
	bash tests/test-cvg-doctor-evidence.sh
	bash tests/test-cvg-tasks-plan.sh
	bash tests/test-cvg-tasks-dod.sh
	bash tests/test-cvg-lesson.sh
	bash tests/test-install.sh
	bash tests/test-clean-room-install-e2e.sh
	bash tests/test-loop-kernel.sh
	$(PYTHON) tests/test-deliver.py
	bash tests/test-codex-engine.sh
	bash tests/test-version-unity.sh
	bash skills/idea-to-brd/tests/run-tests.sh
	bash skills/brd-docs-to-tech-req/tests/run-tests.sh
	bash skills/tech-req-to-adrs/tests/run-tests.sh
	bash skills/reqs-to-swimlane-plans/tests/run-tests.sh
	bash skills/sketch-plans-adversarial-review/tests/run-tests.sh
	bash skills/pass-to-lesson/tests/run-tests.sh
	bash skills/skill-creator/tests/test-skill-creator.sh
	bash skills/evidence-to-next-pass/tests/run-tests.sh
	python3 skills/task-to-runtime-contract/tests/test-gate-policy.py
	bash tests/test-ci-covers-every-suite.sh
	bash tests/test-repo-layout.sh

check-json:
	bash tests/test-cvg-json-envelope.sh
	$(PYTHON) tests/test-cvg-json-matrix.py

check-docs:
	bash tests/test-docs.sh

check-layout:
	bash tests/test-repo-layout.sh

check-release-assets:
	$(PYTHON) scripts/check-release-assets.py

check-composed:
	bash tests/test-compose.sh

check-package:
	bash tests/test-package.sh


check-memory:
	npm test --prefix tools/memory
check-cockpit:
	npm run cockpit:check
	npm run cockpit:build

check-live-evidence:
	$(PYTHON) scripts/validate-live-evidence.py

demo-composed:
	bash scripts/demo-composed.sh

release-check: check check-cockpit demo-composed check-live-evidence check-release-assets
