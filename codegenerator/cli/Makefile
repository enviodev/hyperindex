# Target to update schemas
update-schemas:
	@echo "Updating schemas json schemas for evm human config..."
	cargo run -- print-config-json-schema evm > ./npm/envio/evm.schema.json
	@echo "Updating schemas json schemas for fuel human config..."
	cargo run -- print-config-json-schema fuel > ./npm/envio/fuel.schema.json

# Target to update help
update-help:
	@echo "Updating help doc..."
	cargo run -- print-cli-help-md > ./CommandLineHelp.md

# Target to update generated docs, depends on update-schemas and update-help
update-generated-docs: update-schemas update-help
