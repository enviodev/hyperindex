/*
Each event handler requires two functions to be registered in order to enable full functionality within the indexer.
1. An `<event>LoadEntities` function
2. An `<event>Handler` function

LoadEntities function follows a naming convention for all events: `register<EventName>LoadEntities`.

Within this function, the user must define the criteria for loading the entity defined in config.yaml file.

Handler function also follows a naming convention for all events in the form of: `register<EventName>Handler`.

Within this function the user must define how the information from the event should create/modify the entities that have been loaded by the loadEntities function.

Entities that match the criteria in loadEntities will be available via the labels defined per entity in config.yaml file.
User can use `context` as the gateway to interact with the indexer and the underlying database.

The `context` also provides the following functions per entity that can be used to interact with that entity:

- insert
- update
- delete

User should import the auto-generated function names for loadEntities and handlers from the Handlers file in `/generated` directory, as well as the entities from Types file in `/generated` directory.

*/
