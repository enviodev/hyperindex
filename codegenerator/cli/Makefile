# Target to update schemas
update-schemas:
	@echo "Updating schemas json schemas for evm human config..."
	cargo run -- script print-config-json-schema evm > ./npm/envio/evm.schema.json
	@echo "Updating schemas json schemas for fuel human config..."
	cargo run -- script print-config-json-schema fuel > ./npm/envio/fuel.schema.json

# Target to update help
update-help:
	@echo "Updating help doc..."
	cargo run -- script print-cli-help-md > ./CommandLineHelp.md

# Target to update help
print-missing-networks:
	@echo "Printing missing networks..."
	cargo run -- script print-missing-networks

# Target to update generated docs, depends on update-schemas and update-help
update-generated-docs: update-schemas update-help

# Runs rustfmt with format_strings option.
format:
	@echo "Formatting code"
	cargo fmt -- --config format_strings=true
