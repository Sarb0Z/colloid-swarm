#!/usr/bin/env python3
"""Decide whether a migration-applying command reaches a hosted database.

guard-publish.py loads this for a command whose tool applies migrations, seeds
or schema pushes (`prisma migrate deploy`, `alembic upgrade`, `rails
db:migrate`, ...). Such a command against a developer's local database is
routine work done many times a day; the same command against a hosted database
changes production state. So the verb alone decides nothing: the database the
tool will connect to does, and an ask that fires on every local migration is
one people learn to dismiss.

The target is resolved the way the tool resolves it, from what can be read
without running project code:

* an explicit URL argument (`--url`, knex `--connection`, a mongosh URI);
* the variables the tool reads — Prisma's schema `env()` names for `url` and
  `directUrl`, Alembic's literal `sqlalchemy.url` plus `DATABASE_URL`, and
  `DATABASE_URL` for the tools whose configuration is code (Rails, Django,
  Flask, knex, Sequelize, TypeORM, drizzle) — each looked up in the command's
  own assignments, then the process environment, then the env files a
  `dotenv -e` wrapper names, then the env files the tool itself loads, walked
  from the command's directory up to the repository root;
* when none of that names a URL, every database-looking variable in the
  command, the environment and the repository root's env files (the
  operator's ruling of 2026-10-11): quiet only when at least one exists and
  every one is local.

Local means a loopback host (localhost, 127.0.0.0/8, ::1), a unix socket, or
an SQLite/file URL. Anything else asks, and so does a URL that does not parse,
an earlier part of the same command line that exports, unsets or sources a
database variable, and a command the guard cannot locate. A reason names a
host and where it came from, never the URL: the URL carries the password.

Two places are never local: a migration run over ssh reaches the far
machine's database even at `localhost`, and one run under a platform or
secrets runner (`heroku run`, `kubectl exec`, `doppler run`, ...) gets its
database from the platform; both ask. Files are read only for a command that
runs on this machine from inside the repository, from a directory the guard
could follow. The threat model is guard-publish's: an honest mistake, not an
adversary — a config file that computes its URL in code is not followed.
"""

import configparser
import ipaddress
import json
import os
import re
from urllib.parse import parse_qs, unquote

# Migration, seed and schema-push verbs, per tool. A phrase of two words is
# matched against the first two positional arguments; Rails and rake accept
# several tasks in one call, so any of their positionals counts. `prisma
# migrate dev` and `migrate resolve` write to the datasource too: dev applies
# pending migrations (and offers a reset), resolve edits the migrations table.
RAILS_TASKS = {"db:migrate", "db:migrate:redo", "db:migrate:up", "db:migrate:down",
               "db:rollback", "db:schema:load", "db:structure:load", "db:seed",
               "db:seed:replant", "db:drop", "db:drop:all", "db:reset", "db:setup",
               "db:prepare", "db:purge", "db:truncate_all", "db:create", "db:fixtures:load"}
# A Rails task with a suffix (`db:migrate:primary`, `db:schema:load:animals`)
# is the multi-database form of its prefix, except these, which only read.
RAILS_READS = {"db:migrate:status", "db:version", "db:schema:dump", "db:structure:dump",
               "db:schema:cache:dump", "db:schema:cache:clear", "db:abort_if_pending_migrations"}
TYPEORM_VERBS = {"migration:run", "migration:revert", "schema:sync", "schema:drop"}
SEQUELIZE_VERBS = {"db:migrate", "db:migrate:undo", "db:migrate:undo:all", "db:seed",
                   "db:seed:all", "db:seed:undo", "db:seed:undo:all", "db:drop"}
VERBS = {
    "prisma": {"migrate deploy", "migrate reset", "migrate dev", "migrate resolve", "db push",
               "db execute", "db seed"},
    "alembic": {"upgrade", "downgrade", "stamp"},
    "rails": RAILS_TASKS,
    "rake": RAILS_TASKS,
    "typeorm": TYPEORM_VERBS,
    "typeorm-ts-node-commonjs": TYPEORM_VERBS,
    "typeorm-ts-node-esm": TYPEORM_VERBS,
    "drizzle-kit": {"push", "migrate"},
    "knex": {"migrate:latest", "migrate:rollback", "migrate:up", "migrate:down", "seed:run"},
    "sequelize": SEQUELIZE_VERBS,
    "sequelize-cli": SEQUELIZE_VERBS,
    "manage.py": {"migrate", "flush", "loaddata"},
    "django-admin": {"migrate", "flush", "loaddata"},
    "flask": {"db upgrade", "db downgrade", "db stamp"},
}
# drizzle-kit before 0.21 spelled its verbs per dialect: `push:pg`, `migrate:mysql`.
DIALECT_VERBS = {"drizzle-kit": ("push:", "migrate:")}
ANY_POSITIONAL = {"rails", "rake"}
# A mongo shell or loader is gated only when it names a server; bare, it
# connects to localhost.
MONGO_SHELLS = {"mongosh", "mongo"}
MONGO_LOADERS = {"mongorestore", "mongoimport"}
# `python -m <module>` names a tool by its module.
MODULES = {"django": "django-admin"}
DOTENV_WRAPPERS = {"dotenv", "dotenv-cli"}
# Every word that can name one of these tools in a command line; guard-publish
# must list each in GATED_NAMES or it never loads this module.
NAMES = set(VERBS) | MONGO_SHELLS | MONGO_LOADERS | set(MODULES)

# Options that take a separate value, per tool, so that value is not read as a
# verb or operand.
VALUE_FLAGS = {
    "prisma": {"--schema", "--url", "--file", "--config", "--name"},
    "alembic": {"-c", "--config", "-n", "--name", "-x", "-m", "--message"},
    "rails": {"-e", "--environment"},
    "rake": {"-f", "--rakefile", "-C", "--directory", "-e", "--execute"},
    "typeorm": {"-d", "--dataSource", "-c", "--connection", "-f", "--config", "-t", "--transaction"},
    "drizzle-kit": {"--config", "--url", "--dialect"},
    "knex": {"--knexfile", "--knexpath", "--cwd", "--env", "--client", "--connection",
             "--migrations-directory", "--migrations-table-name", "--specific"},
    "sequelize": {"--env", "--config", "--options-path", "--migrations-path", "--seeders-path",
                  "--models-path", "--url", "--to", "--from", "--name", "--seed"},
    "manage.py": {"--database", "--settings", "--pythonpath", "-v", "--verbosity"},
    "flask": {"-A", "--app", "-e", "--env-file", "-d", "--directory"},
    "mongosh": {"--host", "--port", "-u", "--username", "-p", "--password",
                "--authenticationDatabase", "--authenticationMechanism", "--eval", "-f",
                "--file", "--apiVersion", "--tlsCAFile", "--tlsCertificateKeyFile"},
    "mongorestore": {"--uri", "-h", "--host", "--port", "-u", "--username", "-p", "--password",
                     "-d", "--db", "-c", "--collection", "--authenticationDatabase",
                     "--nsInclude", "--nsExclude", "--nsFrom", "--nsTo", "--archive",
                     "-j", "--numParallelCollections", "--config"},
    "mongoimport": {"--uri", "-h", "--host", "--port", "-u", "--username", "-p", "--password",
                    "-d", "--db", "-c", "--collection", "--authenticationDatabase", "--file",
                    "--type", "--fields", "--fieldFile", "--mode", "--upsertFields", "-j",
                    "--numInsertionWorkers", "--config"},
}
for alias, original in (("typeorm-ts-node-commonjs", "typeorm"), ("typeorm-ts-node-esm", "typeorm"),
                        ("sequelize-cli", "sequelize"), ("django-admin", "manage.py"),
                        ("mongo", "mongosh")):
    VALUE_FLAGS[alias] = VALUE_FLAGS[original]
# The argument that names the database outright, when the tool has one.
URL_FLAGS = {"prisma": "--url", "sequelize": "--url", "sequelize-cli": "--url",
             "drizzle-kit": "--url", "knex": "--connection", "mongosh": "--host", "mongo": "--host"}

DATABASE_WORD = re.compile(r"DATABASE|DB|POSTGRES|PG|MYSQL|MONGO")
LOCATOR_WORD = re.compile(r"URL|URI|DSN|HOST")
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
ENV_LINE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*(.*)$")
EXPANSION = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)")
HOST = re.compile(r"[A-Za-z0-9_.-]+")
SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*")
DATASOURCE = re.compile(r"datasource\s+\w+\s*\{(.*?)\}", re.S)
DATASOURCE_URL = re.compile(r'^\s*(url|directUrl)\s*=\s*(?:env\(\s*"([^"]+)"\s*\)|"([^"]*)")', re.M)
# Shell words that set, export or drop a variable for the commands after them.
SETTERS = {"export", "declare", "typeset", "readonly", "unset"}
SOURCERS = {"source", "."}
MAX_BYTES = 512 * 1024


def database_variable(name):
    """True for a name that conventionally holds a database location."""
    upper = name.upper()
    return bool(DATABASE_WORD.search(upper) and LOCATOR_WORD.search(upper))


def positionals(words, valued):
    found, skip = [], False
    for word in words:
        if skip:
            skip = False
        elif word.startswith("-"):
            skip = word in valued
        else:
            found.append(word)
    return found


def flag_value(words, flag):
    """The value of `flag` given as `flag value` or `flag=value`, else None."""
    for index, word in enumerate(words):
        if word == flag and index + 1 < len(words):
            return words[index + 1]
        if word.startswith(flag + "="):
            return word.split("=", 1)[1]
    return None


def flag_values(words, flags):
    found = []
    for index, word in enumerate(words):
        if word in flags and index + 1 < len(words):
            found.append(words[index + 1])
        elif "=" in word and word.split("=", 1)[0] in flags:
            found.append(word.split("=", 1)[1])
    return found


def tool_call(name, rest, base):
    """(tool, arguments) for a migration tool named by `name`, else None.
    `python manage.py ...` and `python -m django ...` name Django's tool."""
    if name.startswith("python") and rest and base(rest[0]) == "manage.py":
        return "manage.py", rest[1:]
    name = MODULES.get(name, name)
    return (name, rest) if name in VERBS or name in MONGO_SHELLS | MONGO_LOADERS else None


def phrase(tool, rest):
    """The migration verb the arguments run, or None."""
    words = positionals(rest, VALUE_FLAGS.get(tool, set()))
    verbs = VERBS[tool]
    if tool in ANY_POSITIONAL:
        return next((word for word in words if rails_applies(word)), None)
    for width in (2, 1):
        candidate = " ".join(words[:width])
        if len(words) >= width and candidate in verbs:
            return candidate
    if words and words[0].startswith(DIALECT_VERBS.get(tool, ())):
        return words[0]
    return None


def rails_applies(task):
    """True for a Rails task that writes to a database, in its plain or its
    multi-database (`db:migrate:primary`) form."""
    if any(task == read or task.startswith(read + ":") for read in RAILS_READS):
        return False
    return any(task == applying or task.startswith(applying + ":") for applying in RAILS_TASKS)


def inside(path, root):
    if not path or not root or not os.path.isabs(path):
        return False
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def read_text(path):
    """A file's text; a file too large for an env or config file is refused
    rather than half-read, so the caller fails closed."""
    if os.path.getsize(path) > MAX_BYTES:
        raise ValueError(f"{path} is larger than {MAX_BYTES} bytes")
    with open(path, encoding="utf-8-sig", errors="replace") as handle:
        return handle.read()


def parse_env(text):
    """The assignments of a dotenv file, quotes removed; a repeated name keeps
    its last value, as dotenv and python-dotenv do."""
    found = {}
    for line in text.splitlines():
        match = ENV_LINE.match(line)
        if not match:
            continue
        name, value = match.group(1), match.group(2).strip()
        if value[:1] in ("'", '"') and value[0] in value[1:]:
            value = value[1:value.index(value[0], 1)]
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
        found[name] = value
    return found


class Context:
    """What one command can be resolved against: the variables it sets
    itself, the process environment, and the env files it may load."""

    def __init__(self, here, repo, remote, environ):
        self.here = here
        self.repo = repo
        self.remote = remote
        # Files are read only for a local command run from inside the repository.
        self.readable = not remote and inside(here, repo)
        self.environ = {} if remote else dict(environ)
        self.inline = {}
        self.files = []          # (label, assignments), first definition wins
        self._parsed = {}

    def label(self, path):
        real = os.path.realpath(path)
        return os.path.relpath(real, os.path.realpath(self.repo)) if inside(real, self.repo) else path

    def env_file(self, path):
        """A dotenv file's assignments, or None when it does not exist."""
        if path not in self._parsed:
            self._parsed[path] = parse_env(read_text(path)) if os.path.isfile(path) else None
        return self._parsed[path]

    def add_file(self, path):
        assignments = self.env_file(path)
        label = self.label(path)
        if assignments is not None and all(label != known for known, _ in self.files):
            self.files.append((label, assignments))

    def walk(self, names):
        """Load each named env file from the command's directory up to the
        repository root, nearest first."""
        if not self.readable:
            return
        directory, top = os.path.realpath(self.here), os.path.realpath(self.repo)
        while True:
            for name in names:
                self.add_file(os.path.join(directory, name))
            if directory == top or os.path.dirname(directory) == directory:
                return
            directory = os.path.dirname(directory)

    def lookup(self, name):
        """(value, source) for a variable the tool would see, else None."""
        if self.inline.get(name):
            return self.inline[name], f"{name} on the command line"
        if self.environ.get(name):
            return self.environ[name], f"{name} in the environment"
        for label, assignments in self.files:
            if assignments.get(name):
                return assignments[name], f"{name} in {label}"
        return None


def expand(value, context, depth=0):
    """The value with `$NAME` and `${NAME:-default}` references resolved the
    way dotenv-expand resolves them, or None when one cannot be."""
    if "$" not in value:
        return value
    if depth > 4:
        return None
    failed = []

    def substitute(match):
        name = match.group(1) or match.group(3)
        found = context.lookup(name)
        if found:
            resolved = expand(found[0], context, depth + 1)
            if resolved is not None:
                return resolved
        if match.group(2) is not None:
            return match.group(2)
        failed.append(name)
        return ""

    result = EXPANSION.sub(substitute, value)
    return None if failed or "$" in result else result


def split_host(item):
    """(host, valid) for one `host[:port]` item of a URL's authority."""
    item = unquote(item)
    if item.startswith("/"):
        return item, True                               # a unix socket path
    if item.startswith("["):
        host, _, after = item[1:].partition("]")
        port = after[1:] if after.startswith(":") else after
    elif item.count(":") > 1:
        host, port = item, ""                           # a bare IPv6 address
    else:
        host, _, port = item.partition(":")
    if port and not (port.isdigit() and int(port) <= 65535):
        return host, False
    return host, nameable(host)


def nameable(host):
    """True for a host safe to print: a hostname or an IP address. Anything
    else may be a fragment of a malformed URL, such as its password."""
    if HOST.fullmatch(host):
        return True
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def local_host(host):
    host = host.strip().lower()
    if host.startswith("/"):
        return True
    if host == "localhost" or host.endswith(".localhost"):
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def hosts_of(name, value, context):
    """The hosts a variable's value connects to: a list, [] for a local
    default (a socket or a file), or None when the value does not parse."""
    value = expand(value.strip(), context)
    if value is None:
        return None
    lowered = value.lower()
    if lowered.startswith(("file:", "sqlite")):
        return []
    if "://" not in value:
        if name.upper().endswith(("HOST", "HOSTADDR")):
            hosts = []
            for item in value.split(","):
                host, valid = split_host(item.strip())
                if not valid or not host:
                    return None
                hosts.append(host)
            return hosts or None
        if "=" in value:                                 # a libpq keyword DSN
            keywords = dict(re.findall(r"(\w+)\s*=\s*'?([^\s']*)'?", value))
            host = keywords.get("host") or keywords.get("hostaddr")
            return host.split(",") if host else libpq_default(context)
        return None
    scheme, _, remainder = value.partition("://")
    if not SCHEME.fullmatch(scheme):
        return None
    authority = re.split(r"[/?#]", remainder, maxsplit=1)[0]
    tail = remainder[len(authority):]
    query = parse_qs(tail.split("?", 1)[1].split("#", 1)[0]) if "?" in tail else {}
    hosts = []
    listed = authority.rpartition("@")[2]
    for item in listed.split(",") if listed else []:
        host, valid = split_host(item)
        if not valid:
            return None
        hosts.append(host)
    for given in query.get("host", []) + query.get("hostaddr", []):
        hosts.extend(part for part in given.split(",") if part)
    if hosts:
        return hosts
    if scheme.lower().startswith("postgres"):
        return libpq_default(context)
    if scheme.lower().startswith(("mysql", "mariadb")):
        return []
    return None


def libpq_default(context):
    """The hosts libpq uses when a connection string names none: PGHOST or
    PGHOSTADDR, else its local socket."""
    for variable in ("PGHOST", "PGHOSTADDR"):
        found = context.lookup(variable)
        if found:
            return hosts_of(variable, found[0], context)
    return []


def problem(label, name, value, source, context):
    """Why `value` is not provably local, or None when it is."""
    hosts = hosts_of(name, value, context)
    if hosts is None:
        return (f"{label}: the database URL in {source} does not parse, so the guard cannot "
                "tell whether it is local.")
    for host in hosts:
        if local_host(host):
            continue
        shown = host if nameable(host) else "a host that is not a loopback address"
        reason = (f"{label} reaches the database at {shown}, named by {source}; only a "
                  "loopback host, a unix socket or an SQLite file counts as local.")
        if "." not in host and ":" not in host:
            reason += (" A bare name such as a docker-compose service is not provably "
                       "local, so it asks too.")
        return reason
    return None


def taint(earlier, context):
    """What an earlier part of the command line does to a database variable
    that the guard cannot follow, or None."""
    for words in earlier:
        while words and words[0] in ("if", "then", "else", "elif", "do", "while", "until", "!", "{"):
            words = words[1:]
        if not words:
            continue
        head = os.path.basename(words[0])
        # `eval "$(cat .env.production)"` and `env $(cat f) ...` set variables
        # from text the guard never sees. A command substitution is split off
        # by the parser, leaving `eval`/`env` with a bare `$` or nothing.
        if head == "eval" and (len(words) == 1 or any("$" in word or "`" in word for word in words[1:])):
            return "runs `eval` on a computed string"
        if head == "env" and any("$" in word or "`" in word for word in words[1:]):
            return "runs `env` with computed assignments"
        if all(ASSIGNMENT.match(word) for word in words):
            names = [ASSIGNMENT.match(word).group(1) for word in words]
        elif head in SETTERS:
            names = [word.split("=", 1)[0] for word in words[1:] if not word.startswith("-")]
            if any("$" in name for name in names):
                return f"runs `{head}` on a computed name"
        elif head in SOURCERS and len(words) > 1:
            found = sourced(words[1], context)
            if found:
                return found
            continue
        else:
            continue
        named = [name for name in names if database_variable(name)]
        if named:
            return f"sets or unsets {named[0]} with `{head if head in SETTERS else 'an assignment'}`"
    return None


def sourced(path, context):
    """Why sourcing `path` may change a database variable, or None when the
    file is read and sets none."""
    if "$" in path or "`" in path:
        return f"sources a computed path ({path})"
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        if not context.readable:
            return f"sources {path}, which the guard cannot read from here"
        path = os.path.join(context.here, path)
    if not context.readable:
        return f"sources {path}, which the guard cannot read from here"
    if not os.path.isfile(path):
        return None
    for line in read_text(path).splitlines():
        match = re.match(r"^\s*(?:export\s+|declare\s+-x\s+)?([A-Za-z_][A-Za-z0-9_]*)(?:=|\s*$)", line)
        if match and database_variable(match.group(1)):
            return f"sources {context.label(path)}, which sets {match.group(1)}"
    return None


def prisma_schema(rest, context):
    """The .prisma files the command reads: `--schema`, package.json's
    `prisma.schema`, or Prisma's default locations."""
    given = flag_value(rest, "--schema")
    if given:
        paths = [os.path.join(context.here, given)]
    else:
        paths, directory = [], os.path.realpath(context.here)
        top = os.path.realpath(context.repo)
        while True:
            manifest = os.path.join(directory, "package.json")
            if os.path.isfile(manifest):
                document = json.loads(read_text(manifest))
                configured = document.get("prisma") if isinstance(document, dict) else None
                schema = configured.get("schema") if isinstance(configured, dict) else None
                if isinstance(schema, str) and schema:
                    paths.append(os.path.join(directory, schema))
                break
            if directory == top or os.path.dirname(directory) == directory:
                break
            directory = os.path.dirname(directory)
        if not paths:
            paths = [os.path.join(context.here, "prisma", "schema.prisma"),
                     os.path.join(context.here, "schema.prisma"),
                     os.path.join(context.here, "prisma", "schema")]
    for path in paths:
        if os.path.isdir(path):
            return sorted(os.path.join(path, name) for name in os.listdir(path)
                          if name.endswith(".prisma"))
        if os.path.isfile(path):
            return [path]
    return []


def prisma_candidates(rest, context):
    """Prisma connects through the datasource's `url` and, for migrations,
    `directUrl`; it loads `.env` (not `.env.local`) beside the project and
    beside the schema."""
    candidates = []
    if not context.readable:
        return candidates
    schema = prisma_schema(rest, context)
    for path in schema:
        # A `//` comment, but not the `//` inside a quoted URL.
        text = re.sub(r'("(?:[^"\\]|\\.)*")|//[^\n]*', lambda match: match.group(1) or "",
                      read_text(path))
        for block in DATASOURCE.findall(text):
            for field, variable, literal in DATASOURCE_URL.findall(block):
                if variable:
                    candidates.append(("variable", variable))
                elif literal:
                    candidates.append(("literal", literal, f"the datasource {field} in {context.label(path)}"))
    context.walk([".env"])
    for path in schema:
        if inside(path, context.repo):
            context.add_file(os.path.join(os.path.dirname(path), ".env"))
    return candidates


def alembic_candidates(rest, context):
    """Alembic connects through env.py, which is code: commonly the literal
    `sqlalchemy.url` in alembic.ini, commonly `DATABASE_URL`. Both are judged."""
    candidates = []
    if context.readable:
        config = flag_value(rest, "-c") or flag_value(rest, "--config")
        config = config or (context.lookup("ALEMBIC_CONFIG") or ("alembic.ini",))[0]
        path = os.path.join(context.here, config)
        section = flag_value(rest, "-n") or flag_value(rest, "--name") or "alembic"
        if os.path.isfile(path):
            parser = configparser.RawConfigParser(strict=False)
            parser.read_string(read_text(path))
            url = parser.get(section, "sqlalchemy.url", fallback="").replace("%%", "%").strip()
            if url and "%(" not in url and "$" not in url:
                candidates.append(("literal", url, f"sqlalchemy.url in {context.label(path)}"))
        context.walk([".env"])
    return candidates + [("variable", "DATABASE_URL")]


def rails_candidates(rest, context):
    """Rails merges DATABASE_URL over database.yml in every environment;
    dotenv-rails loads these files for the environment, most specific first."""
    environment = (flag_value(rest, "-e") or flag_value(rest, "--environment")
                   or (context.lookup("RAILS_ENV") or ("development",))[0])
    names = [f".env.{environment}.local"] + ([".env.local"] if environment != "test" else [])
    context.walk(names + [f".env.{environment}", ".env"])
    return [("variable", "DATABASE_URL")]


def default_candidates(tool, rest, context):
    """Tools whose configuration is code: DATABASE_URL from the environment or
    `.env` (and `.flaskenv` for Flask, which loads both)."""
    if tool == "flask":
        if context.readable:
            for given in flag_values(rest, {"-e", "--env-file"}):
                context.add_file(os.path.join(context.here, given))
        context.walk([".env", ".flaskenv"])
    else:
        context.walk([".env"])
    return [("variable", "DATABASE_URL")]


def root_env_files(repo):
    names = sorted(name for name in os.listdir(repo)
                   if (name == ".env" or name.startswith(".env."))
                   and not name.endswith((".example", ".sample", ".template")))
    return [os.path.join(repo, name) for name in names]


def mongo_targets(tool, rest):
    """(variable, value, source) for each server a mongo shell or loader is
    pointed at; empty when it names none and so connects to localhost.

    mongosh's first operand that is not a script file is its database
    address: a connection string, `host/db`, `host:port/db` or `host:port`.
    A bare word is a database name on localhost, as mongosh documents it."""
    found = []
    operands = positionals(rest, VALUE_FLAGS[tool])
    if tool in MONGO_SHELLS:
        address = next((word for word in operands if not word.endswith((".js", ".mongodb"))), None)
        operands = [address] if address else []
    for word in operands:
        if "://" in word:
            found.append(("MONGO_URL", word, "the connection string argument"))
        elif tool in MONGO_SHELLS and ("/" in word or ":" in word or "." in word):
            found.append(("MONGO_HOST", word.split("/", 1)[0], "the database address argument"))
    uri = flag_value(rest, "--uri")
    if uri:
        found.append(("MONGO_URL", uri, "the --uri argument"))
    for flag in ("--host", "-h") if tool in MONGO_LOADERS else ("--host",):
        host = flag_value(rest, flag)
        if host:
            # `--host rs0/h1:27017,h2:27017` names a replica set before the hosts.
            found.append(("MONGO_URL", host, f"the {flag} argument") if "://" in host
                         else ("MONGO_HOST", host.split("/", 1)[-1], f"the {flag} argument"))
    return found


def remote_reason(label, remote):
    return (f"{label} runs on {remote} over ssh, where even a loopback address is that "
            "machine's database.")


def verdict(name, rest, stripped, earlier, here, repo, remote, base, environ=None,
            platform=None, lost=False):
    """The reason to ask before this command, or None.

    `stripped` is the prefix guard-destructive's lead() removed (assignments
    and wrappers), `earlier` the word lists of the command line's earlier
    segments, `here` the directory the command runs in, `repo` the repository
    root, `remote` the ssh host a command runs on (empty when local),
    `platform` the platform runner it runs under (`heroku run`), and `lost`
    true when an earlier `cd` went where the guard cannot follow.
    """
    call = tool_call(name, rest, base)
    if not call:
        return None
    tool, rest = call
    if "-h" in rest or "--help" in rest:
        return None
    context = Context(here, repo, remote, os.environ if environ is None else environ)

    if tool in MONGO_SHELLS | MONGO_LOADERS:
        targets = mongo_targets(tool, rest)
        if remote:
            return remote_reason(tool, remote)
        for variable, value, source in targets:
            found = problem(tool, variable, value, source, context)
            if found:
                return found
        return None

    verb = phrase(tool, rest)
    if verb is None:
        return None
    label = f"{tool} {verb}"
    if platform:
        return (f"{label} runs under `{platform}`, which supplies the database from the hosting "
                "platform's environment, so it reaches the hosted database.")
    if remote:
        return remote_reason(label, remote)

    named_files = []
    for kind, words in stripped:
        if kind == "=":
            match = ASSIGNMENT.match(words)
            context.inline.setdefault(match.group(1), match.group(2))
        elif kind in DOTENV_WRAPPERS:
            for value in flag_values(words, {"-v"}):
                match = ASSIGNMENT.match(value)
                if match:
                    context.inline.setdefault(match.group(1), match.group(2))
            named_files += dotenv_files(words)
        elif kind == "env-file":
            named_files += words
    if tool in ANY_POSITIONAL:
        # rake reads `NAME=value` operands as environment variables.
        for word in positionals(rest, VALUE_FLAGS[tool]):
            match = ASSIGNMENT.match(word)
            if match:
                context.inline.setdefault(match.group(1), match.group(2))

    tainted = taint(earlier, context)
    if tainted:
        return (f"{label}: an earlier part of this command {tainted}, so the guard cannot "
                "tell which database it reaches.")

    flag = URL_FLAGS.get(tool)
    explicit = flag_value(rest, flag) if flag else None
    if explicit:
        return problem(label, "DATABASE_URL", explicit, f"the {flag} argument", context)
    if lost:
        return (f"{label}: an earlier `cd`, `pushd` or `popd` goes to a directory the guard cannot "
                "follow, so it cannot read the env files the tool loads there.")

    if named_files and not context.readable:
        return (f"{label} loads {', '.join(named_files)}, which the guard reads only for a "
                "command run from inside the repository.")
    for given in named_files:
        context.add_file(os.path.join(context.here, given))

    if tool == "prisma":
        candidates = prisma_candidates(rest, context)
    elif tool == "alembic":
        candidates = alembic_candidates(rest, context)
    elif tool in ANY_POSITIONAL:
        candidates = rails_candidates(rest, context)
    else:
        candidates = default_candidates(tool, rest, context)

    resolved = []
    for candidate in candidates:
        if candidate[0] == "literal":
            resolved.append(("DATABASE_URL", candidate[1], candidate[2]))
        else:
            found = context.lookup(candidate[1])
            if found:
                resolved.append((candidate[1], found[0], found[1]))
    if not resolved:
        resolved = fallback(context)
        if not resolved:
            return (f"{label}: no database URL is set on the command line, in the environment "
                    "or in the repository's env files, so the guard cannot tell whether it "
                    "reaches a local database.")
    for variable, value, source in resolved:
        found = problem(label, variable, value, source, context)
        if found:
            return found
    return None


def dotenv_files(options):
    """The files a dotenv wrapper loads, from its recorded options: dotenv-cli's
    `-e file` and `-c [env]` cascade, the Ruby gem's `-f a,b`, python-dotenv's
    `-f/--file`."""
    files = []
    for index, word in enumerate(options):
        value = options[index + 1] if index + 1 < len(options) else ""
        if word == "-e":
            files.append(value)
        elif word in ("-f", "--file"):
            files += [name for name in value.split(",") if name]
        elif word == "-c":
            environment = "" if value.startswith("-") else value
            files += ([f".env.{environment}.local", ".env.local", f".env.{environment}", ".env"]
                      if environment else [".env.local", ".env"])
    return files


def fallback(context):
    """Every database-looking variable the command could see: its own
    assignments, the environment, the env files it names and the repository
    root's env files (examples and templates excluded)."""
    found = [(name, value, f"{name} on the command line")
             for name, value in context.inline.items() if database_variable(name) and value]
    found += [(name, value, f"{name} in the environment")
              for name, value in sorted(context.environ.items()) if database_variable(name) and value]
    if context.readable:
        for path in root_env_files(context.repo):
            context.add_file(path)
    for label, assignments in context.files:
        found += [(name, value, f"{name} in {label}")
                  for name, value in assignments.items() if database_variable(name) and value]
    return found
