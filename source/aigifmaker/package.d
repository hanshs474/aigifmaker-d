/**
 * Official D SDK for AI GIF Maker (https://aigifmaker.ai): turn text into
 * animated GIFs.
 *
 * ---
 * import aigifmaker;
 * auto r = generate("a corgi in sunglasses dancing on a beach");
 * if (r.ok) writeln(r.url); else writeln(r.reason, ": ", r.message);
 * ---
 *
 * Set `Options.apiKey` or AIGIFMAKER_API_KEY; create a key at
 * https://aigifmaker.ai/settings/apikeys. Each GIF costs 1 credit on your
 * AI GIF Maker account, the same as on the website. Uses std.net.curl.
 */
module aigifmaker;

import core.thread : Thread;
import core.time : msecs, seconds;
import std.algorithm : canFind;
import std.datetime.systime : Clock;
import std.json;
import std.net.curl : HTTP;
import std.process : environment;
import std.string : strip, toLower;

/// Why a call failed, in terms of what to do next.
enum Reason { none, auth, quota, rejected, failed, timeout, other }

/// The outcome of a call: a GIF URL (or task id) in `url`, or why there is none.
struct Result { bool ok; string url; Reason reason; string message; }

/// A task's record from `status`.
struct Status
{
    bool ok;
    string id;
    string status;        /// pending, processing, success or failed
    string url;           /// the GIF when status is success
    bool queued;          /// waiting in the queue (accounts that have not bought credits yet)
    string errorMessage;
    string failureKind;
    Reason reason;
    string message;
}

/// Call settings. `Options.init` is valid.
struct Options
{
    string apiKey;              /// default AIGIFMAKER_API_KEY
    int pollMillis = 3000;
    int timeoutSeconds = 900;
}

/// Service root, changeable for a test or a proxy.
__gshared string baseUrl = "https://aigifmaker.ai";

/// POST a JSON body and return the decoded answer. Replaceable in tests.
__gshared JSONValue delegate(string url, string body, string key) transport;

enum keysUrl = "https://aigifmaker.ai/settings/apikeys";
enum pricingUrl = "https://aigifmaker.ai/pricing";

shared static this()
{
    transport = (string url, string body, string key) {
        auto http = HTTP(url);
        http.method = HTTP.Method.post;
        // Without a key the request still goes out: the service answers with a wall, which becomes Reason.auth.
        if (key.length) http.addRequestHeader("Authorization", "Bearer " ~ key);
        http.addRequestHeader("Content-Type", "application/json");
        http.addRequestHeader("User-Agent", "aigifmaker-d/0.1.0");
        http.postData = body;
        ubyte[] buf;
        http.onReceive = (ubyte[] d) { buf ~= d; return d.length; };
        http.perform();
        try return parseJSON(cast(string) buf.idup);
        catch (Exception) return JSONValue.init;
    };
}

private JSONValue emptyObj()
{
    JSONValue[string] m;
    return JSONValue(m);
}

private bool has(const JSONValue v, string k)
{
    return v.type == JSONType.object && (k in v.object) !is null;
}

private string str(const JSONValue v, string k)
{
    return has(v, k) && v[k].type == JSONType.string ? v[k].str : "";
}

private bool flag(const JSONValue v, string k)
{
    return has(v, k) && v[k].type == JSONType.true_;
}

/// Map a refusal (JSON code other than 0) to the reason that says what to do next.
Reason classify(long code, string message)
{
    auto low = message.toLower;
    if (low.canFind("invalid api key") || low.canFind("no auth")) return Reason.auth;
    if (low.canFind("insufficient credits")) return Reason.quota;
    if (code != 0 && code != -1) return Reason.rejected;
    return Reason.other;
}

private Result fail(Reason r, string msg) { return Result(false, null, r, "aigifmaker: " ~ msg); }

/// Every answer is HTTP 200; the JSON code tells success from refusal.
private Result call(string path, JSONValue body, string apiKey, out JSONValue data)
{
    auto key = apiKey.length ? apiKey : environment.get("AIGIFMAKER_API_KEY", "");
    JSONValue env;
    try env = transport(baseUrl ~ path, body.toString, key.strip);
    catch (Exception e) return fail(Reason.other, e.msg);
    if (!has(env, "code") || env["code"].type != JSONType.integer)
        return fail(Reason.other, "unexpected answer from the service");
    auto code = env["code"].integer;
    if (code != 0)
    {
        auto msg = str(env, "message");
        if (!msg.length) msg = "request refused";
        auto why = classify(code, msg);
        return fail(why, why == Reason.quota ? msg ~ "; top up at " ~ pricingUrl : msg);
    }
    data = has(env, "data") && env["data"].type == JSONType.object ? env["data"] : emptyObj();
    if (flag(data, "wall"))
        return fail(Reason.auth, "an API key is required; create one at " ~ keysUrl ~ " and set AIGIFMAKER_API_KEY");
    return Result(true);
}

/// Start one GIF and return its task id in `Result.url` without waiting.
Result submit(string prompt, Options o = Options.init)
{
    if (prompt.strip.length == 0) return fail(Reason.other, "prompt is required");
    JSONValue body = [
        "provider": JSONValue("openlux"),
        "mediaType": JSONValue("image"),
        "model": JSONValue("gif-maker-v1"),
        "scene": JSONValue("text-to-image"),
        "prompt": JSONValue(prompt),
        "options": JSONValue(["output_format": "gif"]),
    ];
    JSONValue d;
    auto r = call("/api/ai/generate", body, o.apiKey, d);
    if (!r.ok) return r;
    auto id = str(d, "id");
    if (!id.length) return fail(Reason.other, "the service returned no task id");
    return Result(true, id);
}

/// Look up a task.
Status status(string id, string apiKey = null)
{
    JSONValue d;
    auto r = call("/api/ai/query", JSONValue(["taskId": id]), apiKey, d);
    Status s;
    if (!r.ok) { s.reason = r.reason; s.message = r.message; return s; }
    s.ok = true;
    s.id = str(d, "id");
    s.status = str(d, "status");
    if (has(d, "images") && d["images"].type == JSONType.array && d["images"].array.length
        && d["images"].array[0].type == JSONType.string)
        s.url = d["images"].array[0].str;
    s.queued = flag(d, "queued");
    s.errorMessage = str(d, "errorMessage");
    s.failureKind = str(d, "failureKind");
    return s;
}

/// Remaining credits on the account (free to call). -1 with `reason` set on failure.
long credits(string apiKey = null, Reason* reason = null)
{
    JSONValue d;
    auto r = call("/api/user/get-user-credits", emptyObj(), apiKey, d);
    if (r.ok && has(d, "remainingCredits") && d["remainingCredits"].type == JSONType.integer)
        return d["remainingCredits"].integer;
    if (reason) *reason = r.ok ? Reason.other : r.reason;
    return -1;
}

/// Poll a task until it succeeds, fails or the deadline passes; return the GIF URL.
Result wait(string id, Options o = Options.init)
{
    auto deadline = Clock.currTime + o.timeoutSeconds.seconds;
    while (true)
    {
        auto s = status(id, o.apiKey);
        if (s.ok)
        {
            if (s.status == "success" && s.url.length) return Result(true, s.url);
            if (s.status == "failed" || s.status == "canceled")
            {
                auto msg = s.errorMessage.length ? s.errorMessage : "the GIF " ~ s.status;
                return fail(s.failureKind == "moderation" ? Reason.rejected : Reason.failed, msg);
            }
        }
        else if (s.reason != Reason.other)
            return Result(false, null, s.reason, s.message);
        // a dropped poll is not a failed GIF
        if (Clock.currTime + o.pollMillis.msecs >= deadline) break;
        Thread.sleep(o.pollMillis.msecs);
    }
    return fail(Reason.timeout, "still running; task " ~ id ~ " may finish later in your AI GIF Maker history");
}

/// Generate one animated GIF and return its URL.
Result generate(string prompt, Options o = Options.init)
{
    auto r = submit(prompt, o);
    return r.ok ? wait(r.url, o) : r;
}

unittest
{
    JSONValue[] bodies;
    string[] urls;
    string[] keys;
    string[] replies;
    auto saved = transport;
    scope (exit) transport = saved;
    transport = (string url, string body, string key) {
        urls ~= url;
        keys ~= key;
        bodies ~= parseJSON(body);
        auto r = replies[0];
        replies = replies[1 .. $];
        return parseJSON(r);
    };
    enum submitted = `{"code":0,"message":"ok","data":{"id":"task_1","status":"pending","taskId":"up_9","provider":"openlux"}}`;
    Options o = { apiKey: "sk-x", pollMillis: 0, timeoutSeconds: 5 };

    replies = [
        submitted,
        `{"code":0,"message":"ok","data":{"id":"task_1","status":"processing","images":[],"queued":true,"queueEta":40}}`,
        `{"code":0,"message":"ok","data":{"id":"task_1","status":"success","images":["https://cdn.aigifmaker.ai/g/task_1.gif"],"watermarked":[true]}}`,
    ];
    auto g = generate("a corgi dancing", o);
    assert(g.ok && g.url == "https://cdn.aigifmaker.ai/g/task_1.gif");
    assert(urls[0].canFind("/api/ai/generate") && keys[0] == "sk-x");
    auto b = bodies[0];
    assert(b["provider"].str == "openlux" && b["mediaType"].str == "image" && b["model"].str == "gif-maker-v1");
    assert(b["scene"].str == "text-to-image" && b["prompt"].str == "a corgi dancing" && b["options"]["output_format"].str == "gif");
    assert(urls[1].canFind("/api/ai/query") && bodies[1]["taskId"].str == "task_1");

    replies = [`{"code":0,"message":"ok","data":{"remainingCredits":42,"made":3}}`];
    assert(credits("sk-x") == 42);

    replies = [submitted, `{"code":0,"message":"ok","data":{"id":"task_1","status":"failed","errorMessage":"upstream error","refundNote":"credit returned"}}`];
    auto f = generate("x", o);
    assert(!f.ok && f.reason == Reason.failed && f.message.canFind("upstream error"));
    replies = [submitted, `{"code":0,"message":"ok","data":{"id":"task_1","status":"failed","errorMessage":"blocked","failureKind":"moderation"}}`];
    assert(generate("x", o).reason == Reason.rejected);

    struct Case { string body; Reason want; }
    foreach (c; [
        Case(`{"code":-1,"message":"invalid API key — create one at https://aigifmaker.ai/settings/apikeys"}`, Reason.auth),
        Case(`{"code":-1,"message":"no auth, please sign in"}`, Reason.auth),
        Case(`{"code":0,"message":"ok","data":{"wall":true,"reason":"anon_credits"}}`, Reason.auth),
        Case(`{"code":-1,"message":"insufficient credits"}`, Reason.quota),
        Case(`{"code":-2,"message":"content cooldown"}`, Reason.rejected),
        Case(`{"code":-1,"message":"upstream busy"}`, Reason.other),
    ])
    {
        replies = [c.body];
        auto r = submit("x", o);
        assert(!r.ok && r.reason == c.want, c.body);
    }

    // Two free live checks (no generation): AIGIFMAKER_SMOKE=1 dub test
    if (environment.get("AIGIFMAKER_SMOKE", "").length)
    {
        transport = saved;
        Reason why;
        assert(credits("sk-invalidtest000", &why) == -1 && why == Reason.auth, "live wrong key");
        Options none = { apiKey: " " };
        auto w = submit("a cat waving", none);
        assert(!w.ok && w.reason == Reason.auth, "live wall: " ~ w.message);
    }
}
