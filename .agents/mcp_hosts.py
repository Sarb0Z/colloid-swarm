"""Which hosts render a registry entry.

An entry's optional `hosts` list names the hosts that render it; an entry
without one renders on every host. Each renderer asks `renders` and keeps its
own rendering of an excluded server: Claude, Codex and OpenCode omit it, Kimi
writes a disabled record. Type limits (an SSE server Codex and OpenCode cannot
run) stay in those renderers.
"""

HOSTS = ("claude", "codex", "kimi", "opencode")
REMOVED = ("codex_enabled", "kimi_enabled")


def renders(server, host):
    return host in server.get("hosts", HOSTS)


def validate(name, server, fail):
    for field in REMOVED:
        if field in server:
            fail(f"{name}.{field} was replaced by `hosts`, a list of the hosts that render it "
                 f"(any of {', '.join(HOSTS)}); list the hosts instead")
    if "hosts" not in server:
        return
    hosts = server["hosts"]
    if not isinstance(hosts, list) or not hosts or not all(isinstance(item, str) for item in hosts):
        fail(f"{name}.hosts must be a non-empty list of host names ({', '.join(HOSTS)})")
    unknown = sorted(set(hosts) - set(HOSTS))
    if unknown:
        fail(f"{name}.hosts has unknown host(s): {', '.join(unknown)}; known hosts are {', '.join(HOSTS)}")
    if len(set(hosts)) != len(hosts):
        fail(f"{name}.hosts must list each host once")
