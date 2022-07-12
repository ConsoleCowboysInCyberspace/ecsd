///
module ecsd.event.entity_pubsub;

import ecsd.entity: EntityID, Entity;
import ecsd.event: isEvent;
import ecsd.universe;

/++
	A component implementing an entity->entity event model similar to `ecsd.event.pubsub`.
+/
struct PubSub
{
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
	+/
	void subscribe(Event)(void delegate(Entity, ref Event) fn, int priority = 0)
	if(isEvent!Event)
	{
		import std.algorithm: sort;
		auto ptr = typeid(Event) in handlers;
		if(ptr is null)
			ptr = &(handlers[typeid(Event)] = []);
		*ptr ~= EventHandler(fn, priority);
		(*ptr).sort!"a.priority > b.priority";
	}
	
	/// ditto
	void subscribe(Event)(void function(Entity, ref Event) fn, int priority = 0)
	if(isEvent!Event)
	{
		import std.functional: toDelegate;
		subscribe(toDelegate(fn), priority);
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
	}
	
	/// ditto
	void publish(Event)()
	if(isEvent!Event)
	{
		publish(Event.init);
	}
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
	
	bool calledf1, calledf2;
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
	
	PubSub pubsub;
	pubsub.onComponentAdded(uni, targetEntity);
	pubsub.subscribe(&f1);
	pubsub.subscribe(&f2, 1);
	
	static struct Bar {}
	static void f3(Entity, ref Bar) { assert(false); }
	pubsub.subscribe(&f3);
	
	Foo ev = { 1 };
	pubsub.publish(ev);
	assert(calledf1);
	assert(calledf2);
	assert(ev.x == 2);
	calledf1 = calledf2 = false;
	
	pubsub.publish(Foo());
	assert(calledf1);
	assert(calledf2);
	calledf1 = calledf2 = false;
	
	pubsub.publish!Foo;
	assert(calledf1);
	assert(calledf2);
	
	static struct UnusedEvent {}
	pubsub.publish!UnusedEvent;
}
