# OnymSearch — extraction notes

Search owns the message-search results screen and result presentation. It
depends on **OnymChatsCore** for message queries and **OnymIdentity** for the
active-owner scope.

`SearchView` receives two app-owned closures instead of importing chat UI:

- `startChats` starts the app's chat-group observer.
- `groupNameForID` resolves a search result's group name.

The app shell owns `navigationDestination(for: MessageSearchResult.self)` and
constructs `ChatThreadView`. This keeps the package independent of the
remaining app-local chat UI while preserving the Search tab's navigation
stack.
