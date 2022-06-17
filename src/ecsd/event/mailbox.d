module ecsd.event.mailbox;

import std.algorithm;
import std.typecons;
import std.variant;

import ecsd.event: isEvent;

alias MailboxPeek = Flag!"MailboxPeek";

struct Mailbox
{
	import ecsd.event: isEvent;
	
	enum maxMessageSizeBytes = 1024;
	private alias MsgVariant = VariantN!maxMessageSizeBytes;
	
	private MsgVariant[] messages;
	
	void send(Msg)(auto ref Msg message)
	if(isEvent!Msg)
	{
		static assert(
			Msg.sizeof <= maxMessageSizeBytes,
			Msg.stringof ~ " is too large to be stored in a " ~ typeof(this).stringof,
		);
		// FIXME: considering elements are a 1k struct, this is rather inefficient
		// relatedly: need to expire messages that are never recv'd
		messages ~= MsgVariant(message);
	}
	
	void send(Msg)()
	if(isEvent!Msg)
	{
		send(Msg.init);
	}
	
	Nullable!Msg tryRecv(Msg)(MailboxPeek peek = MailboxPeek.no)
	if(isEvent!Msg)
	{
		foreach(i, ref v; messages)
			if(auto ptr = v.peek!Msg)
			{
				scope(exit) if(peek == MailboxPeek.no)
					messages = messages.remove(i);
				return typeof(return)(*ptr);
			}
		
		return typeof(return).init;
	}
}

unittest
{
	struct Msg { int x; }
	Mailbox mbox;
	mbox.send(Msg(42));
	
	assert(mbox.tryRecv!Msg(MailboxPeek.yes).get(Msg.init) == Msg(42));
	assert(mbox.tryRecv!Msg.get(Msg.init) == Msg(42));
	assert(mbox.tryRecv!Msg.isNull);
}
