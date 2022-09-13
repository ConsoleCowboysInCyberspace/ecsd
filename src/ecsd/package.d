///
module ecsd;

public import ecsd.cache;
public import ecsd.entity;
public import ecsd.event.entity_pubsub;
public import ecsd.event.pubsub;
public import ecsd.storage;
public import ecsd.universe;

/++
	Registers into the given universe all components provided by the library, using the default
	storage implementation.
+/
void registerBuiltinComponents(Universe uni)
{
	uni.registerComponent!Spawned;
	uni.registerComponent!PubSub;
}
