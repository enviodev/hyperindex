# Schema validation and specification

All json is valid yaml/yml, and json schema's are typically used for yaml too. It also means that our users can define their schemas in json too potenitally.

The config schema is in the `config.schema.json` file.

To validate the config files we use the `ajv` javascript cli library.

Install this library with `npm install -g ajv-cli`.

Then run the following to validate the config files:

```bash
ajv validate -s ./config.schema.json -d ../scenarios/gravitar/config.yaml
ajv validate -s ./config.schema.json -d ../scenarios/lens/config.yaml
```
