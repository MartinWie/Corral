// corral-hook <agent> [event]
//
// Called synchronously by agent hooks (Claude Code waits for it), so it must be close to free:
// plain C, no JSON parsing. Inside a Corral terminal (CORRAL_SURFACE_ID set) it forwards the hook
// JSON from stdin to the app's Unix socket as one line:
//   {"surface":"…","agent":"…","event":"…","payload":<stdin JSON or null>}
// Outside Corral, and on any error, it does nothing. Always exits 0 and prints nothing.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define MAX_PAYLOAD (1 << 20)  // larger payloads (huge tool output) are sent without payload
#define STDIN_TIMEOUT_MS 2000  // the agent writes stdin and closes it right away
#define SEND_BUDGET_MS 250     // total; a stuck app must never stall the agent

typedef struct {
    char *data;
    size_t len, cap;
} buf_t;

static int buf_put(buf_t *b, const char *s, size_t n) {
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 4096;
        while (cap < b->len + n + 1) cap *= 2;
        char *p = realloc(b->data, cap);
        if (!p) return -1;
        b->data = p;
        b->cap = cap;
    }
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = 0;
    return 0;
}

static int buf_puts(buf_t *b, const char *s) { return buf_put(b, s, strlen(s)); }

/// JSON string with escaping (agent/event/surface come from argv/env).
static int buf_json_string(buf_t *b, const char *s) {
    if (buf_put(b, "\"", 1)) return -1;
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        char esc[8];
        if (c == '"' || c == '\\') {
            esc[0] = '\\'; esc[1] = (char)c;
            if (buf_put(b, esc, 2)) return -1;
        } else if (c < 0x20) {
            snprintf(esc, sizeof esc, "\\u%04x", c);
            if (buf_puts(b, esc)) return -1;
        } else if (buf_put(b, (const char *)&c, 1)) {
            return -1;
        }
    }
    return buf_put(b, "\"", 1);
}

static long long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

/// Reads stdin fully; returns 1 when it was read completely and fit under MAX_PAYLOAD.
static int read_stdin(buf_t *b) {
    char chunk[65536];
    int fits = 1;
    for (;;) {
        struct pollfd p = {STDIN_FILENO, POLLIN, 0};
        int r = poll(&p, 1, STDIN_TIMEOUT_MS);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return 0;  // timeout or error: send the event without payload
        ssize_t n = read(STDIN_FILENO, chunk, sizeof chunk);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return 0;  // EAGAIN etc.: incomplete, don't forward a truncated payload
        if (n == 0) break;
        // Keep draining an oversized payload so the writer never sees EPIPE.
        if (!fits || b->len + (size_t)n > MAX_PAYLOAD) { fits = 0; continue; }
        if (buf_put(b, chunk, (size_t)n)) return 0;
    }
    return fits;
}

static int is_space(char c) { return c == ' ' || c == '\n' || c == '\r' || c == '\t'; }

/// Cheap shape check (no parsing): starts with '{' and ends with '}'. Anything else is sent as
/// null so a broken payload can't make the whole line invalid and lose the event.
static int looks_like_json_object(const buf_t *b) {
    size_t i = 0, j = b->len;
    while (i < j && is_space(b->data[i])) i++;
    while (j > i && is_space(b->data[j - 1])) j--;
    return j - i >= 2 && b->data[i] == '{' && b->data[j - 1] == '}';
}

/// Commands the agent itself runs (Claude's Bash tool) must not report into this terminal.
static void scrub_env_file(const char *path) {
    FILE *f = fopen(path, "a");
    if (!f) return;
    fputs("unset CORRAL_SURFACE_ID CORRAL_HOOK CORRAL_SOCKET\n", f);
    fclose(f);
}

static void send_line(const char *socket_path, const buf_t *line) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(socket_path) >= sizeof addr.sun_path) return;
    strcpy(addr.sun_path, socket_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    long long deadline = now_ms() + SEND_BUDGET_MS;
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0) {
        size_t off = 0;
        while (off < line->len) {
            ssize_t n = write(fd, line->data + off, line->len - off);
            if (n > 0) { off += (size_t)n; continue; }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && errno != EAGAIN) break;
            long long left = deadline - now_ms();
            if (left <= 0) break;  // app not reading (stopped, debugger): give up, never stall
            struct pollfd p = {fd, POLLOUT, 0};
            if (poll(&p, 1, (int)left) <= 0) break;
        }
    }
    close(fd);
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    const char *surface = getenv("CORRAL_SURFACE_ID");
    if (!surface || !*surface || argc < 2) return 0;
    const char *agent = argv[1];
    const char *event = argc > 2 ? argv[2] : "";

    char fallback[PATH_MAX];
    const char *socket_path = getenv("CORRAL_SOCKET");
    if (!socket_path || !*socket_path) {
        const char *home = getenv("HOME");
        if (!home) return 0;
        snprintf(fallback, sizeof fallback, "%s/Library/Application Support/Corral/corral.sock", home);
        socket_path = fallback;
    }

    buf_t payload = {0};
    int has_payload = 0;
    if (!isatty(STDIN_FILENO)) has_payload = read_stdin(&payload) && looks_like_json_object(&payload);

    if (strcmp(agent, "claude") == 0 && strcmp(event, "SessionStart") == 0) {
        const char *env_file = getenv("CLAUDE_ENV_FILE");
        if (env_file && *env_file) scrub_env_file(env_file);
    }

    buf_t line = {0};
    int err = buf_puts(&line, "{\"surface\":") || buf_json_string(&line, surface)
        || buf_puts(&line, ",\"agent\":") || buf_json_string(&line, agent)
        || buf_puts(&line, ",\"event\":") || buf_json_string(&line, event)
        || buf_puts(&line, ",\"payload\":");
    if (!err) {
        // Payload is passed through verbatim; the app parses it. Newlines inside JSON
        // strings are escaped, so stripping raw ones keeps the one-line framing.
        if (has_payload) {
            for (size_t i = 0; i < payload.len; i++) {
                if (payload.data[i] == '\n' || payload.data[i] == '\r') payload.data[i] = ' ';
            }
            err = buf_put(&line, payload.data, payload.len);
        } else {
            err = buf_puts(&line, "null");
        }
        if (!err) err = buf_puts(&line, "}\n");
    }
    if (!err) send_line(socket_path, &line);
    free(payload.data);
    free(line.data);
    return 0;
}
