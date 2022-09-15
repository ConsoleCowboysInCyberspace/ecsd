///
module ecsd.event.entity_pubsub;

import std.algorithm;
import std.functional: toDelegate;

import ecsd.entity: EntityID, Entity;
import ecsd.event: isEvent;
import ecsd.universe;
import globalPubsub = ecsd.event.pubsub;

///
public import ecsd.event.pubsub: Unsubscribe;

/++
	A component implementing an entity->entity event model similar to `ecsd.event.pubsub`.
+/
struct PubSub
{
	enum ecsdSerializable = false;
	private EntityID owningEnt;
	private EventHandler[][TypeInfo] handlers;
	
	void onComponentAdded(Universe, EntityID owner)
	{
		owningEnt = owner;
	}
	
	void onComponentRemoved(Universe, EntityID)
	{
		handlers.clear;
	}
	
	/++
		Register the given function to be called whenever an event of the corresponding type is
		`publish`ed to this entity.
		
		Params:
		priority = dispatch order of event handlers, descending (larger priorities execute first)
		
		See_Also: `ecsd.event.pubsub.subscribe` for caveats
	+/
	void delegate(Entity, ref Event) subscribe(Event)(void delegate(Entity, ref Event) fn, int priority = 0)
	if(isEvent!Event)
	{
		auto ptr = typeid(Event) in handlers;
		if(ptr is null)
			ptr = &(handlers[typeid(Event)] = []);
		*ptr ~= EventHandler(fn, priority);
		(*ptr).sort!"a.priority > b.priority";
		return fn;
	}
	
	/// ditto
	void delegate(Entity, ref Event) subscribe(Event)(void function(Entity, ref Event) fn, int priority = 0)
	if(isEvent!Event)
	{
		return subscribe(toDelegate(fn), priority);
	}
	
	/++
		A version of `subscribe` accepting subscribers which may request an unsubscribe simply via
		return value, avoiding having to cache somewhere the returned delegate.
	+/
	void delegate(Entity, ref Event) subscribeTransient(Event)(Unsubscribe delegate(Entity, ref Event) fn, int priority = 0)
	{
		// FIXME: investigate whether this can be optimized, even if only taking pressure off the array
		// of non-transients with another array; std.algrithm.merge can be used to recombine them
		void delegate(Entity, ref Event) subscriber;
		subscriber = subscribe((Entity ent, ref Event ev) {
			if(fn(ent, ev) == Unsubscribe.yes)
				unsubscribe(subscriber);
		}, priority);
		return subscriber;
	}

	/// ditto
	void delegate(Entity, ref Event) subscribeTransient(Event)(Unsubscribe function(Entity, ref Event) fn, int priority = 0)
	{
		return subscribeTransient(fn.toDelegate, priority);
	}

	/++
		A `subscribeTransient` optimized for subscribers which wish to receive only a fixed number of
		events before unsubscribing.
		
		Params:
		numEvents = number of events to process before unsubscribing, clamped to a minimum of 1
	+/
	void delegate(Entity, ref Event) subscribeCounting(Event)(void delegate(Entity, ref Event) fn, size_t numEvents, int priority = 0)
	{
		size_t eventsProcessed;
		void delegate(Entity, ref Event) subscriber;
		subscriber = subscribe((Entity ent, ref Event ev) {
			fn(ent, ev);
			if(++eventsProcessed >= numEvents)
				unsubscribe(subscriber);
		}, priority);
		return subscriber;
	}

	/// ditto
	void delegate(Entity, ref Event) subscribeCounting(Event)(void function(Entity, ref Event) fn, size_t numEvents, int priority = 0)
	{
		return subscribeCounting(fn.toDelegate, numEvents, priority);
	}
	
	/++
		Removes the given function from the list of subscribers. Does nothing if the given
		function/delegate has already been unsubscribed, or hadn't been subscribed at all.
	
		See_Also: `ecsd.event.pubsub.subscribe` for caveats
	+/
	void unsubscribe(Event)(void delegate(Entity, ref Event) fn)
	if(isEvent!Event)
	{
		auto ptr = typeid(Event) in handlers;
		if(ptr is null) return;
		auto evs = *ptr;
		size_t index = evs.countUntil!(eh => eh.context == fn.ptr && eh.function_ == fn.funcptr);
		if(index == -1) return;
		*ptr = evs.remove(index);
	}
	
	/// ditto
	void unsubscribe(Event)(void function(Entity, ref Event) fn)
	if(isEvent!Event)
	{
		unsubscribe(fn.toDelegate);
	}
	
	/++
		Immediately dispatches the given event, passing it to all subscribers registered to this entity.
	+/
	void publish(Event)(auto ref Event ev)
	if(isEvent!Event)
	{
		auto ent = Entity(owningEnt);
		foreach(handler; handlers.get(typeid(Event), null))
			handler.reconstruct!Event()(ent, ev);
		globalPubsub.publish(EntityEvent!Event(ent, ev));
	}
	
	/// ditto
	void publish(Event)()
	if(isEvent!Event)
	{
		publish(Event.init);
	}
}

/++
	A `ecsd.event.pubsub` event published by all `PubSub` components after an entity event has been
	published, allowing subscription to events on every entity.
+/
struct EntityEvent(Event)
if(isEvent!Event)
{
	Entity entity; /// The entity `event` was published to.
	Event event; /// The event that was published.
	alias event this; ///
}

private struct EventHandler
{
	// to store handlers in the component directly the delgate's type needs to be erased, so we
	// store the pointers accordingly, and enforce correctness by keying handlers on event typeid
	void* context;
	void* function_;
	
	int priority;
	
	this(Event)(void delegate(Entity, ref Event) fn, int priority)
	{
		context = fn.ptr;
		function_ = fn.funcptr;
		this.priority = priority;
	}
	
	void delegate(Entity, ref Event) reconstruct(Event)()
	{
		typeof(return) result;
		result.ptr = context;
		result.funcptr = cast(typeof(result.funcptr))function_;
		return result;
	}
}

unittest
{
	static struct Foo
	{
		int x = -1;
	}
	
	auto uni = allocUniverse;
	scope(exit) freeUniverse(uni);
	auto targetEntity = uni.allocEntity;
	
	bool calledf1, calledf2, calledf3;
	void f1(Entity ent, ref Foo)
	{
		assert(ent.id == targetEntity);
		assert(!calledf1);
		assert(calledf2);
		calledf1 = true;
	}
	void f2(Entity ent, ref Foo ev)
	{
		assert(ent.id == targetEntity);
		assert(!calledf1);
		assert(!calledf2);
		calledf2 = true;
		assert(ev.x == -1 || ev.x == 1);
		ev.x = 2;
	}
	void f3(ref EntityEvent!Foo ev)
	{
		assert(ev.entity.id == targetEntity);
		assert(!calledf3);
		calledf3 = true;
	}
	
	PubSub pubsub;
	pubsub.onComponentAdded(uni, targetEntity);
	auto ptrF1 = pubsub.subscribe(&f1);
	auto ptrF2 = pubsub.subscribe(&f2, 1);
	globalPubsub.subscribe(&f3);
	
	bool calledTrans1, calledTrans2;
	pubsub.subscribeTransient((Entity, ref Foo _) {
		assert(calledf1);
		assert(calledf2);
		calledTrans1 = true;
		return Unsubscribe.yes;
	}, -1);
	pubsub.subscribeCounting((Entity, ref Foo _) {
		assert(calledf1);
		assert(calledf2);
		assert(calledTrans1);
		calledTrans2 = true;
	}, 1, -2);
	
	static struct Bar {}
	static void f4(Entity, ref Bar) { assert(false); }
	pubsub.subscribe(&f4);
	
	Foo ev = { 1 };
	pubsub.publish(ev);
	assert(calledf1);
	assert(calledf2);
	assert(calledf3);
	assert(calledTrans1);
	assert(calledTrans2);
	assert(ev.x == 2);
	
	static assert(__traits(compiles, { pubsub.publish(Foo()); }));
	static assert(__traits(compiles, { pubsub.publish!Foo; }));
	
	calledf1 = calledf2 = calledf3 = false;
	calledTrans1 = calledTrans2 = false;
	ev.x = 1;
	pubsub.unsubscribe(ptrF1);
	pubsub.unsubscribe(ptrF2);
	pubsub.publish(ev);
	assert(!calledf1);
	assert(!calledf2);
	assert(calledf3);
	assert(!calledTrans1);
	assert(!calledTrans2);
	assert(ev.x == 1);
	
	static struct UnusedEvent {}
	pubsub.publish!UnusedEvent;
}
