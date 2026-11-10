# aigifmaker-d

Turn text into animated GIFs with AI GIF Maker. Native GIF generation — no video conversion. Type what you want and download your GIF in about a minute.

This is the official D SDK for [AI GIF Maker](https://aigifmaker.ai/?utm_source=dub&utm_medium=package). One call sends your prompt, waits for the GIF and returns its URL.

```d
import aigifmaker;

auto r = generate("a corgi in sunglasses dancing on a beach, looping");
if (r.ok) writeln(r.url); else writeln(r.reason, ": ", r.message);  // the finished GIF
```

## Install

```bash
dub add aigifmaker
```

Uses `std.net.curl`, no other dependencies. The package also has a `cli` configuration (`dub build -c cli`) that builds an `aigifmaker` command: `aigifmaker "a prompt"` prints a GIF URL, `aigifmaker --credits` your remaining credits.

## API key

Create a key at https://aigifmaker.ai/settings/apikeys, then set `Options.apiKey` or export it:

```bash
export AIGIFMAKER_API_KEY=sk-...
```

Each GIF costs 1 credit on your AI GIF Maker account, the same as on the website. New accounts get one free GIF (it carries a small aigifmaker.ai badge). A GIF that fails to generate gives its credit back. Credit packs are on the [pricing](https://aigifmaker.ai/pricing?utm_source=dub&utm_medium=package) page.

```d
writeln(credits());   // remaining credits, free to call
```

## Submit now, collect later

```d
auto id = submit("happy birthday text bouncing in rainbow letters").url;
auto s = status(id);   // s.status: pending | processing | success | failed; s.url when done
auto r = wait(id);     // polls every 3 seconds
```

A run from an account that has not bought credits yet may wait in a short queue first (`s.queued` is true while `status` stays `processing`). That is normal; `generate` and `wait` keep polling. `Options` takes `apiKey`, `pollMillis` (3000) and `timeoutSeconds` (900).

## Errors worth catching

Failures come back as `Result.ok == false` with a `Reason`:

- `auth`: no key, or the key is wrong or deleted
- `quota`: the account is out of credits
- `rejected`: the content filter refused the prompt, or a cooldown is active; reword it
- `failed`: the run was accepted but failed; the message says why
- `timeout`: the wait ran out; the GIF may still finish in your history

Anything else is `other` with the server's message.

## Tests

```bash
dub test                       # mocked, offline
AIGIFMAKER_SMOKE=1 dub test    # plus two free live checks, no generation
```

MIT licensed. Questions: support@aigifmaker.ai
