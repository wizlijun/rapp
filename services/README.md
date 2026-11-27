# services/

Standalone services that sit beside rApp. Today there is one: `center/` (`rapp-center`, 中心服务). Rules (spec section 12):

1. The main app does not depend on anything here.
2. A service does not reference the main app's crates; they only meet over a shared port and the `api/` description.
3. Both sides test against the same samples in `api/`.

`llm/` is reserved for later; it is to be reached through the center service (rapp-center design §9).
