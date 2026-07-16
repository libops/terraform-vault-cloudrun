.PHONY: actionlint check docs docs-check fmt fmt-check init test tflint validate

TERRAFORM ?= terraform
TERRAFORM_DOCS ?= terraform-docs
TFLINT ?= tflint
ACTIONLINT ?= actionlint

fmt:
	$(TERRAFORM) fmt -recursive .

fmt-check:
	$(TERRAFORM) fmt -check -recursive .

init:
	$(TERRAFORM) init -backend=false -input=false

validate: init
	$(TERRAFORM) validate

test: init
	$(TERRAFORM) test

tflint:
	$(TFLINT) --init
	$(TFLINT) --recursive

actionlint:
	$(ACTIONLINT)

docs:
	$(TERRAFORM_DOCS) markdown table --lockfile=false --output-file README.md .

docs-check:
	$(TERRAFORM_DOCS) markdown table --lockfile=false --output-check --output-file README.md .

check: fmt-check validate test tflint actionlint docs-check
