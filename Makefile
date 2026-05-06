OTEL_DIR := tools/otel-tail
OTEL_BIN := bin/otel
SHEAFTUI_OPEN_BIN := bin/sheaftui-open
SHEAF_ADMIN_BIN := bin/sheaf-admin

.PHONY: all escripts sheaf-admin otel build-otel sheaftui-open clean-otel clean-escripts FORCE

all: escripts

otel: $(OTEL_BIN)

build-otel: $(OTEL_BIN)

sheaftui-open: $(SHEAFTUI_OPEN_BIN)

escripts: sheaf-admin

sheaf-admin: $(SHEAF_ADMIN_BIN)

$(SHEAF_ADMIN_BIN): FORCE
	mix escript.build

$(OTEL_BIN): FORCE
	cd $(OTEL_DIR) && go build -o ../../$(OTEL_BIN) .

clean-escripts:
	rm -f $(SHEAF_ADMIN_BIN)

clean-otel:
	rm -f $(OTEL_BIN)

FORCE:
