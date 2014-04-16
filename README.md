APIncrementalStore
==================

I have just published this repository, the documentation is pretty lame at the moment. More to come.

Cutting the long story short, after StackMob went to hell and all my development based on that SDK as well, I decided to implement my own NSIncrementalStore subclass.
Yes I have looked around for alternatives and even taking into account what is available, none of them are at the moment how I had architectured my app.
I need an implementation that works most of time offline and sync with the backend BaaS when internet is available, which is quite the opposite of the APIs that I had found.
Special thanks to the great Mattt Thompson for the inspiring AFIncrementalStore (https://github.com/AFNetworking/AFIncrementalStore)

There are basically three main classes:

1) APIncrementalStore - this is the NSIncrementalStore subclass that implements what is required to handle the Core Data context.

2) APLocalCache - the APIncrementalStore uses this class as a local core data cache to respond to all core data requests. This class exchanges NSDictionaries representations of the managed objects and uses a objectID to uniquely identify them across the managed contexts (NSIncrementalStore and Local Cache)

3) APParseConnector - Responsible to merge the local cache context in background as requested by the cache.

I will include descent documentation in the next weeks, for the time being take a look at the folder Example in the repository, you are going to find a very basic usade of this library.

Well, that's it, sorry about the short README and the English as it's not my first idiom as you have probably noticed at this point.

###Parse Framework
I have not managed to find a way to staticly include the Parse library or even better include it as a dependency (Parse doesn't have a Pod available). Therefore you need to include it manually:
![Link parse framework](https://dl.dropboxusercontent.com/u/628444/GitHub%20Images/APIncrementalStore_parse.png)

###Few tips:
- Set Parse keys at appDelegate.m
- Login with an user (PFUser) and pass it as paramenter to APIncrementalStore.
- The parse connector will sync all entities found on your model and use the exactly same entity naming to find the classes from Parse.
- I have done nothing in regards to Parse ACL yet, so that it will sync everything that the logged user has access to.
- I'm still planning to do something about the situation when the user changes, for example invalidate the cache or some other smarter aproach.

###Unit Testing
On UnitTestingCommon.m config Parse keys and a valid user. Use a test Parse App as it will include few Classes for testing. 


Cheers. Flavio


