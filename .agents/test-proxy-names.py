#!/usr/bin/env python3
# Seam: .agents/lib/proxy.py read by path, against env files and config documents made in a temporary folder.
# Catches: a name that does not resolve to the split dictionary, a refused file mode, a scheme row, a
#   sentinel password (or a line of the file) in any error text, and a redactor that misses a form of the secret.
# Misses: the launcher's wiring (test-scrapling-proxy.sh), mcp_playwright's own messages (test-mcp.sh), and
#   any real proxy: every password here is a sentinel.
"""Gate named proxies and the proxy URL split against fixture env files."""

import importlib.util
import json
import logging
import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote

here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("colloid_proxy", here / "lib/proxy.py")
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)

PASSWORD = "Zq7-Sentinel!pw#42"
ENCODED = quote(PASSWORD, safe="")
NEIGHBOUR = "Neighbour-Sentinel-9"
MALFORMED = "Malformed-Sentinel-7"
SECRETS = (PASSWORD, ENCODED, NEIGHBOUR, MALFORMED)
fails = 0


def check(name, ok, detail=""):
    global fails
    if ok:
        print(f"ok    {name}")
    else:
        fails += 1
        print(f"FAIL  {name}{(chr(10) + '  ' + str(detail)) if detail else ''}")


def failure(call, *args):
    try:
        call(*args)
    except proxy.ProxyError as error:
        return str(error)
    return None


def clean(message):
    return message is not None and not any(secret in message for secret in SECRETS)


with tempfile.TemporaryDirectory() as folder:
    work = Path(folder)

    def env_file(name, text, mode=0o600):
        path = work / name
        path.write_text(text)
        path.chmod(mode)
        return path

    url = f"http://probe:{ENCODED}@127.0.0.1:3128"
    good = env_file("good.env", f"OTHER=http://x:{NEIGHBOUR}@h:1\nexport NOPE=1\n{MALFORMED}\nPROXY={url}\n")
    named = proxy.Named(good, "PROXY")

    resolved, secrets = proxy.resolve("office", named)
    check("a name resolves to the split dictionary",
          resolved == {"server": "http://127.0.0.1:3128", "username": "probe", "password": PASSWORD}, resolved)
    check("the secrets hold the password raw and percent-encoded and the full URL",
          {PASSWORD, ENCODED, url} <= secrets, sorted(secrets))
    check("the neighbouring key's value is not among the secrets", NEIGHBOUR not in " ".join(secrets))

    value = env_file("equals.env", "PROXY=http://u:a=b=c@127.0.0.1:3128\n")
    check("the value is split at the first = only",
          proxy.resolve("office", proxy.Named(value, "PROXY"))[0]["password"] == "a=b=c")
    quoted = env_file("quoted.env", 'export PROXY="http://u:p@127.0.0.1:3128"\nPROXY2="http://u:p@127.0.0.1:3128"\n')
    check("an export line and a quoted value are not interpreted",
          failure(proxy.resolve, "office", proxy.Named(quoted, "PROXY")) .startswith("proxy 'office'")
          and "no PROXY=" in failure(proxy.resolve, "office", proxy.Named(quoted, "PROXY"))
          and "must use" in failure(proxy.resolve, "office", proxy.Named(quoted, "PROXY2")))

    for label, call_named, expect in (
        ("a missing file", proxy.Named(work / "absent.env", "PROXY"), "does not exist"),
        ("a missing key", proxy.Named(good, "ABSENT"), "no ABSENT=... line"),
        ("an empty value", proxy.Named(env_file("empty.env", f"PROXY=\nOTHER={NEIGHBOUR}\n"), "PROXY"), "value is empty"),
        ("a directory", proxy.Named(work, "PROXY"), "not a regular file"),
        ("a file that is not text", proxy.Named(env_file("binary.env", ""), "PROXY"), "no PROXY=... line"),
    ):
        message = failure(proxy.resolve, "office", call_named)
        check(f"{label} is refused, naming the proxy, key and path, with no secret",
              clean(message) and expect in message and "proxy 'office'" in message
              and str(call_named.env_file) in message and f"key {call_named.key}" in message, message)
    (work / "binary.env").write_bytes(b"PROXY=\xff\xfe\n")
    message = failure(proxy.resolve, "office", proxy.Named(work / "binary.env", "PROXY"))
    check("an env file that is not UTF-8 is refused", message is not None and "not UTF-8" in message, message)

    for mode in (0o644, 0o640, 0o604, 0o660, 0o666, 0o700 | 0o010):
        path = env_file(f"mode-{mode:o}.env", f"PROXY={url}\nOTHER={NEIGHBOUR}\n", mode)
        message = failure(proxy.resolve, "office", proxy.Named(path, "PROXY"))
        check(f"mode {mode:04o} is refused with the chmod 600 instruction",
              clean(message) and "chmod 600" in message and str(path) in message and "proxy 'office'" in message, message)
    for mode in (0o600, 0o400, 0o700):
        path = env_file(f"ok-{mode:o}.env", f"PROXY={url}\n", mode)
        check(f"mode {mode:04o} is read", proxy.resolve("office", proxy.Named(path, "PROXY"))[0]["username"] == "probe")

    # Each scheme row, through the same split the launcher and mcp_playwright use.
    for scheme in proxy.SCHEMES:
        credentials = "" if scheme in proxy.SOCKS_SCHEMES else "u:p%40ss@"
        result = proxy.split_url(f"{scheme}://{credentials}host.example:1080", "x")
        want = {"server": f"{scheme}://host.example:1080"}
        if credentials:
            want |= {"username": "u", "password": "p@ss"}
        check(f"{scheme} splits", result == want, result)
    for scheme in proxy.SOCKS_SCHEMES:
        message = failure(proxy.split_url, f"{scheme}://u:{ENCODED}@host.example:1080", "$X")
        check(f"{scheme} with credentials is refused without the password",
              clean(message) and "Chromium cannot send" in message and message.startswith("$X"), message)
    message = failure(proxy.split_url, f"ftp://u:{ENCODED}@host.example:21", "$X")
    check("an unknown scheme is refused listing the four schemes",
          clean(message) and "must use http, https, socks4, or socks5" in message, message)
    for text in (f"http://u:{ENCODED}@host.example", f"http://u:{ENCODED}@host.example:80/path",
                 f"http://u:{ENCODED}@:80", f"http://u:{ENCODED}@host.example:notaport", "host.example:80"):
        message = failure(proxy.split_url, text, "$X")
        check(f"{text.replace(ENCODED, '<pw>')!r} is refused without the password",
              clean(message) and ("is not a proxy URL" in message or "must use" in message), message)
    check("a {session} token is substituted when one is given",
          proxy.split_url("http://u-{session}:p@h.example:1", "x", "abc")["username"] == "u-abc")

    # The configuration document.
    def config(document):
        path = work / "config.json"
        path.write_text(json.dumps(document))
        return path

    home = os.environ["HOME"]
    names = proxy.load_names(config({"scrapling": {"proxies": {
        "office": {"env_file": "~/x/proxies.env", "key": "OFFICE_PROXY"},
        "eu-2": {"env_file": "/abs/p.env", "key": "EU"}}}}))
    check("load_names expands ~ and keeps the key",
          names == {"office": proxy.Named(Path(home) / "x/proxies.env", "OFFICE_PROXY"),
                    "eu-2": proxy.Named(Path("/abs/p.env"), "EU")}, names)
    check("no config file, no scrapling key and an empty map all mean no names",
          proxy.load_names(work / "none.json") == {} and proxy.load_names(config({})) == {}
          and proxy.load_names(config({"scrapling": {"proxies": {}}})) == {})
    for label, document in (
        ("an uppercase name", {"Office": {"env_file": "/a", "key": "K"}}),
        ("a name that starts with a digit", {"1x": {"env_file": "/a", "key": "K"}}),
        ("a relative env_file", {"x": {"env_file": "a.env", "key": "K"}}),
        ("an extra field", {"x": {"env_file": "/a", "key": "K", "url": "http://h:1"}}),
        ("a key that is not a variable name", {"x": {"env_file": "/a", "key": "a b"}}),
        ("an entry that is not an object", {"x": "http://h:1"}),
    ):
        message = failure(proxy.load_names, config({"scrapling": {"proxies": document}}))
        check(f"{label} is refused", message is not None and "scrapling.proxies" in message, message)
    (work / "config.json").write_text("{not json")
    check("a config that does not parse is refused", "cannot read" in (failure(proxy.load_names, work / "config.json") or ""))

# The redactor.
redactor = proxy.Redactor()
redactor.add("office", {url, PASSWORD, ENCODED})
text = f"bad {url} / {PASSWORD} / {ENCODED} / x"
check("the scrub replaces the full URL, then the password raw and encoded",
      redactor.scrub(text) == "bad <proxy office> / <proxy office> / <proxy office> / x", redactor.scrub(text))
logger = logging.getLogger("test-proxy-names")
logger.propagate = False
captured = []


class Collect(logging.Handler):
    def emit(self, record):
        captured.append(self.format(record))


handler = Collect()
handler.addFilter(redactor)
logger.addHandler(handler)
try:
    raise RuntimeError(f"failed through {url}")
except RuntimeError:
    logger.exception("retry %s", PASSWORD)
logger.warning("plain %s", "text")
check("a log record's message and traceback are scrubbed",
      len(captured) == 2 and PASSWORD not in captured[0] and url not in captured[0] and "<proxy office>" in captured[0]
      and captured[1] == "plain text", captured)

sys.exit(1 if fails else 0)
