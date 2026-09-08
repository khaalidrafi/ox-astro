# Makefile to run ox-astro tests from the command line.
#
# Run "make" to see the help.

MAKE_ := $(MAKE) -j1 --no-print-directory

CURL ?= curl -fsSkL --retry 9 --retry-delay 9

USER ?= me
OX_ASTRO_TMP_DIR_BASE ?= /tmp/$(USER)
ox_astro_tmp_dir ?= $(OX_ASTRO_TMP_DIR_BASE)/ox-astro-dev

ifdef INSIDE_EMACS
	EMACS := $(shell which emacs)
else
	EMACS ?= emacs
endif

# Below is set to 1 during "make test"
TEST_ENABLED=0

# ox-astro test directory; also contains the setup-ox-astro.el
OX_ASTRO_TEST_DIR=$(shell pwd)/test

# Base directory for the Astro example site
OX_ASTRO_TEST_SITE_DIR=$(OX_ASTRO_TEST_DIR)/site

# Directory containing Org files for the test site
OX_ASTRO_TEST_ORG_DIR=$(OX_ASTRO_TEST_SITE_DIR)/content-org

# https://stackoverflow.com/a/3774731/1219634
test_org_files := $(shell find ${OX_ASTRO_TEST_ORG_DIR} -type f -name '*.org')

# Path to the Org file (relative to pwd, or absolute)
ORG_FILE=

# Function to be run in emacs --batch
FUNC=

# Run all tests by default.
TEST_MATCH ?=

test_check=1

.PHONY: help emacs-batch md1 \
	vcheck_emacs vcheck \
	ert test testmkgold \
	do_test $(test_org_files) \
	doc_md doc_gh doc \
	ctemp diffgolden clean

help:
	@echo "Help for ox-astro test runner"
	@echo "=============================="
	@echo " make test           <-- Run ERT tests + golden file diff"
	@echo " make ert            <-- Run only ERT tests"
	@echo " make md             <-- Re-export test Org files to Markdown (no check)"
	@echo " make testmkgold     <-- Rebuild test/site/content-golden from current content"
	@echo " make FOO.org        <-- Export FOO.org to Markdown"
	@echo " make vcheck         <-- Print Emacs and Org versions"
	@echo " make doc            <-- Build doc/content from doc/ox-astro-manual.org"
	@echo " make clean          <-- Delete tmp dir and content-golden"
	@echo " make                <-- Show this help"

# Note: the Org file from $(ORG_FILE) is loaded *after* the --eval
# block so the newer Org version is already in the load-path when
# the file is opened.
emacs-batch:
	@echo ""
	@echo "$(ORG_FILE) ::"
	@env HOME=$(shell pwd)/test $(EMACS) --batch --eval "(progn\
(setenv \"OX_ASTRO_TMP_DIR\" \"$(ox_astro_tmp_dir)\")\
(setenv \"TEST_ENABLED\" \"$(TEST_ENABLED)\")\
(load-file (expand-file-name \"setup-ox-astro.el\" \"$(OX_ASTRO_TEST_DIR)\"))\
)" $(ORG_FILE) \
	-f $(FUNC) \
	--kill

md1:
	@$(MAKE_) emacs-batch FUNC=org-astro-export-all-wim-to-md

vcheck_emacs:
	@mkdir -p $(ox_astro_tmp_dir)
	@$(EMACS) --batch --eval "(progn\
(setenv \"OX_ASTRO_TMP_DIR\" \"$(ox_astro_tmp_dir)\")\
(load-file (expand-file-name \"setup-ox-astro.el\" \"$(OX_ASTRO_TEST_DIR)\"))\
(print-emacs-org-versions)\
)" \
	--kill

vcheck: vcheck_emacs

ert:
	$(EMACS) --batch \
	         --eval "(progn\
(setenv \"OX_ASTRO_TMP_DIR\" \"$(ox_astro_tmp_dir)\")\
(load-file (expand-file-name \"setup-ox-astro.el\" \"$(OX_ASTRO_TEST_DIR)\"))\
    )" \
	         -L . -L $(OX_ASTRO_TEST_DIR)/ert/ \
	         -l all-tests.el \
	         --eval "(ert-run-tests-batch-and-exit \"$(TEST_MATCH)\")"

test: vcheck_emacs ert testmkgold do_test

md: vcheck_emacs
	@$(MAKE_) do_test test_check=0

# Regenerate the golden output from the current content directory.
# https://stackoverflow.com/a/16589534/1219634
testmkgold:
	@git checkout --ignore-skip-worktree-bits -- $(OX_ASTRO_TEST_SITE_DIR)/content
	@rm -rf $(OX_ASTRO_TEST_SITE_DIR)/content-golden
	@cp -rf $(OX_ASTRO_TEST_SITE_DIR)/content $(OX_ASTRO_TEST_SITE_DIR)/content-golden

# Run md1 + diffgolden over all $(test_org_files).
# https://stackoverflow.com/a/37748952/1219634
do_test: $(test_org_files)
$(test_org_files):
	@$(MAKE_) md1 ORG_FILE=$@ TEST_ENABLED=1
ifeq ($(test_check),1)
	@$(MAKE_) diffgolden
endif

doc_md:
	@echo "[Doc Site] Generating ox-astro Documentation Site content .."
	@$(MAKE_) md1 ORG_FILE=./doc/ox-astro-manual.org
	@echo "[Doc Site] Done"

doc_gh:
	@echo "[GitHub Docs] Generating README.org and CONTRIBUTING.org for GitHub .."
	@$(MAKE_) emacs-batch FUNC=ox-astro-export-gh-doc ORG_FILE=./doc/github-files.org
	@echo "[GitHub Docs] Done"

# Requires https://github.com/orhun/git-cliff to be installed.
changelog:
	git cliff -c ./doc/cliff.toml > ./CHANGELOG.org

doc: vcheck_emacs doc_md doc_gh

ctemp:
	@find $(OX_ASTRO_TEST_SITE_DIR)/content -name "*.*~" -delete
	@find ./doc/content -name "*.*~" -delete

# Get rid of all changes in $(OX_ASTRO_TEST_SITE_DIR)/content after
# making a copy to $(OX_ASTRO_TEST_SITE_DIR)/content-modified.
# https://stackoverflow.com/a/16589534/1219634
diffgolden:
	@rm -rf $(OX_ASTRO_TEST_SITE_DIR)/content-modified
	@cp -rf $(OX_ASTRO_TEST_SITE_DIR)/content $(OX_ASTRO_TEST_SITE_DIR)/content-modified
	@git checkout --ignore-skip-worktree-bits -- $(OX_ASTRO_TEST_SITE_DIR)/content
	@diff -r $(OX_ASTRO_TEST_SITE_DIR)/content-modified $(OX_ASTRO_TEST_SITE_DIR)/content-golden

clean: ctemp
	find $(OX_ASTRO_TMP_DIR_BASE) -maxdepth 1 -type d -name ox-astro-dev -exec rm -rf "{}" \;
	find $(OX_ASTRO_TEST_SITE_DIR) -maxdepth 1 -type d \( -name public -o -name content-golden -o -name content-modified \) -exec rm -rf "{}" \;
	find ./doc -maxdepth 1 -type d -name public -exec rm -rf "{}" \;
	rm -f ox-astro-autoloads.el
