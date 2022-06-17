module ecsd;

public import ecsd.cache;
public import ecsd.entity;
public import ecsd.event.mailbox;
public import ecsd.event.pubsub;
public import ecsd.storage;
public import ecsd.universe;

void registerBuiltinComponents(Universe uni)
{
	uni.registerComponent!Mailbox;
	uni.registerComponent!PubSub;
}
