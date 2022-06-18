DDOX_FLAGS := --module-sort=none --decl-sort=none
DDOX_FILTER_FLAGS := --in=ecsd --min-protection=Protected
DOCS_JSON = docs.json
DDOX_ASSETS := $(realpath $(shell dub describe ddox --data-list --data working-directory)/public)

.PHONY: $(DOCS_JSON)
$(DOCS_JSON):
	dub build -b ddox-json
	rm -f __dummy.html

.PHONY: filter-docs
filter-docs: $(DOCS_JSON)
	dub run ddox -- filter $(DDOX_FILTER_FLAGS) $(DOCS_JSON)

.PHONY: docs
docs: filter-docs
	dub run ddox -- generate-html $(DDOX_FLAGS) $(DOCS_JSON) docs/
	cp -r $(DDOX_ASSETS)/* docs/

.PHONY: serve-docs
serve-docs: filter-docs
	dub run ddox -- serve-html $(DDOX_FLAGS) $(DOCS_JSON) --web-file-dir=$(DDOX_ASSETS)
