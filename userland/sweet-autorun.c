/*
 * sweet-autorun: run /private/var/tmp/autorun.sh from a SWEETBOX drop.
 *
 * launchd starts this binary at boot (job com.sweet.autorun, added to
 * /System/Library/xpc/launchd.plist by tools/sweet-launchd-autorun.py). It
 * waits for this boot's /private/var/tmp/SWEETBOX.done to be non-empty (the
 * kernel writes it after extracting the mailbox; it is emptied before
 * launchd), renames autorun.sh to autorun.sh.ran so it runs once, and runs
 * it. Output of the script and its children is relayed to our stdout, which
 * launchd points at /dev/null; the kernel's /dev/null tee (boot-arg
 * sweetnull, which includes sweet-autorun by default since 0400) copies it
 * into the persistent console ring as "|sweet-autorun| SWEET RUN: ...".
 *
 * iOS has no /bin/sh, so this is a tiny line interpreter, not a shell:
 *   - one command per line, '#' starts a comment
 *   - words split on blanks; '...' and "..." quote, \ escapes one character
 *   - a trailing & runs the command in the background
 *   - builtins: cd DIR, sleep SECONDS, export NAME=VALUE, echo ..., wait, exit [N]
 *   - no pipes, redirections, variables or globs
 * Command names without '/' are looked up in PATH (/private/var/tmp first).
 *
 * Adapted from coreycusick/ios-guacamole userland/autorun/sweet-autorun.c
 * (MIT, Copyright (c) 2026 Corey Cusick), reduced for this tree.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define DIR_BOX     "/private/var/tmp"
#define DONE_FILE   DIR_BOX "/SWEETBOX.done"
#define SCRIPT      DIR_BOX "/autorun.sh"
#define SCRIPT_RAN  DIR_BOX "/autorun.sh.ran"
#define WAIT_SECS   300
#define MAX_ARGS    64
#define MAX_JOBS    16

extern char **environ;

struct job {
	pid_t pid;                  /* 0 once reaped */
	int fd;                     /* read end of the output pipe */
	int status;
	bool unreported;
	char name[32];
	char buf[1024];
	size_t len;
};

static struct job jobs[MAX_JOBS];

static void
say(const char *fmt, ...)
{
	char line[1200];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(line, sizeof(line) - 1, fmt, ap);
	va_end(ap);
	if (n < 0) {
		return;
	}
	if ((size_t)n > sizeof(line) - 2) {
		n = sizeof(line) - 2;
	}
	line[n++] = '\n';
	/* One write per line: the kernel tee prints each write as one line. */
	(void)write(STDOUT_FILENO, line, (size_t)n);
}

static void
job_flush_line(struct job *j)
{
	j->buf[j->len] = '\0';
	say("SWEET RUN: [%s] %s", j->name, j->buf);
	j->len = 0;
}

static void
job_report(struct job *j)
{
	if (!j->unreported) {
		return;
	}
	if (WIFEXITED(j->status)) {
		say("SWEET RUN: [%s] exit %d", j->name, WEXITSTATUS(j->status));
	} else if (WIFSIGNALED(j->status)) {
		say("SWEET RUN: [%s] killed by signal %d", j->name, WTERMSIG(j->status));
	}
	j->unreported = false;
}

static void
job_read(struct job *j)
{
	char tmp[512];
	ssize_t n = read(j->fd, tmp, sizeof(tmp));
	if (n <= 0) {
		if (n < 0 && errno == EINTR) {
			return;
		}
		if (j->len) {
			job_flush_line(j);
		}
		close(j->fd);
		j->fd = -1;
		job_report(j);
		return;
	}
	for (ssize_t i = 0; i < n; i++) {
		if (tmp[i] == '\n' || j->len == sizeof(j->buf) - 1) {
			job_flush_line(j);
			if (tmp[i] == '\n') {
				continue;
			}
		}
		j->buf[j->len++] = tmp[i];
	}
}

static void
job_reap(struct job *j, int options)
{
	if (!j->pid || waitpid(j->pid, &j->status, options) != j->pid) {
		return;
	}
	j->pid = 0;
	j->unreported = true;
	if (j->fd < 0) {
		job_report(j);
	}
}

static void
relay(struct job *until)
{
	for (;;) {
		struct pollfd pfd[MAX_JOBS];
		struct job *who[MAX_JOBS];
		int n = 0;
		bool alive = false;
		for (int i = 0; i < MAX_JOBS; i++) {
			if (jobs[i].fd >= 0) {
				pfd[n].fd = jobs[i].fd;
				pfd[n].events = POLLIN;
				who[n++] = &jobs[i];
			}
			job_reap(&jobs[i], WNOHANG);
			alive |= jobs[i].pid != 0 || jobs[i].fd >= 0;
		}
		if (until ? (until->pid == 0 && until->fd < 0) : !alive) {
			return;
		}
		if (until && until->pid == 0 && n == 0) {
			return;
		}
		int r = poll(pfd, (nfds_t)n, 200);
		for (int k = 0; r > 0 && k < n; k++) {
			if (pfd[k].revents) {
				job_read(who[k]);
			}
		}
		if (until && until->pid == 0 && r == 0) {
			job_report(until);
			return;
		}
	}
}

static struct job *
job_slot(void)
{
	for (int i = 0; i < MAX_JOBS; i++) {
		if (jobs[i].pid == 0 && jobs[i].fd < 0) {
			jobs[i].len = 0;
			jobs[i].unreported = false;
			return &jobs[i];
		}
	}
	return NULL;
}

static void
run(char **argv, bool background)
{
	struct job *j = job_slot();
	if (!j) {
		say("SWEET RUN: too many jobs, skipped %s", argv[0]);
		return;
	}
	int p[2];
	if (pipe(p) != 0) {
		say("SWEET RUN: pipe: %s", strerror(errno));
		return;
	}
	posix_spawn_file_actions_t fa;
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
	posix_spawn_file_actions_adddup2(&fa, p[1], STDOUT_FILENO);
	posix_spawn_file_actions_adddup2(&fa, p[1], STDERR_FILENO);
	posix_spawn_file_actions_addclose(&fa, p[0]);
	posix_spawn_file_actions_addclose(&fa, p[1]);
	pid_t pid;
	int err = posix_spawnp(&pid, argv[0], &fa, NULL, argv, environ);
	posix_spawn_file_actions_destroy(&fa);
	close(p[1]);
	if (err) {
		close(p[0]);
		say("SWEET RUN: spawn %s: %s", argv[0], strerror(err));
		return;
	}
	const char *base = strrchr(argv[0], '/');
	snprintf(j->name, sizeof(j->name), "%s", base ? base + 1 : argv[0]);
	j->pid = pid;
	j->fd = p[0];
	say("SWEET RUN: [%s] pid %d%s", j->name, pid, background ? " (background)" : "");
	if (!background) {
		relay(j);
	}
}

/* Splits line in place. Returns the word count, -1 on an open quote. */
static int
split(char *line, char **argv)
{
	int argc = 0;
	char *in = line, *out = line;
	while (*in) {
		while (*in == ' ' || *in == '\t') {
			in++;
		}
		if (!*in || *in == '#') {
			break;
		}
		if (argc == MAX_ARGS - 1) {
			break;
		}
		argv[argc++] = out;
		char quote = 0;
		for (; *in; in++) {
			if (quote) {
				if (*in == quote) {
					quote = 0;
				} else if (*in == '\\' && quote == '"' && in[1]) {
					*out++ = *++in;
				} else {
					*out++ = *in;
				}
			} else if (*in == '\'' || *in == '"') {
				quote = *in;
			} else if (*in == '\\' && in[1]) {
				*out++ = *++in;
			} else if (*in == ' ' || *in == '\t') {
				in++;
				break;
			} else {
				*out++ = *in;
			}
		}
		if (quote) {
			return -1;
		}
		*out++ = '\0';
	}
	argv[argc] = NULL;
	return argc;
}

/* Returns -1 to go on, else the exit status the script asked for. */
static int
line_run(char *line, int lineno)
{
	char *argv[MAX_ARGS];
	int argc = split(line, argv);
	if (argc < 0) {
		say("SWEET RUN: line %d: open quote, skipped", lineno);
		return -1;
	}
	if (argc == 0) {
		return -1;
	}
	bool background = false;
	if (strcmp(argv[argc - 1], "&") == 0) {
		background = true;
		argv[--argc] = NULL;
		if (argc == 0) {
			return -1;
		}
	}
	const char *cmd = argv[0];
	if (strcmp(cmd, "cd") == 0) {
		if (argc < 2 || chdir(argv[1]) != 0) {
			say("SWEET RUN: cd %s: %s", argc < 2 ? "" : argv[1], strerror(errno));
		}
	} else if (strcmp(cmd, "sleep") == 0) {
		double s = argc > 1 ? strtod(argv[1], NULL) : 0;
		struct timespec ts = { (time_t)s, (long)((s - (double)(time_t)s) * 1e9) };
		while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
		}
	} else if (strcmp(cmd, "export") == 0) {
		for (int i = 1; i < argc; i++) {
			char *eq = strchr(argv[i], '=');
			if (eq) {
				*eq = '\0';
				setenv(argv[i], eq + 1, 1);
			}
		}
	} else if (strcmp(cmd, "echo") == 0) {
		char msg[1024];
		size_t len = 0;
		msg[0] = '\0';
		for (int i = 1; i < argc && len < sizeof(msg) - 1; i++) {
			len += (size_t)snprintf(msg + len, sizeof(msg) - len, "%s%s",
			    i > 1 ? " " : "", argv[i]);
		}
		say("SWEET RUN: %s", msg);
	} else if (strcmp(cmd, "wait") == 0) {
		relay(NULL);
	} else if (strcmp(cmd, "exit") == 0) {
		return argc > 1 ? atoi(argv[1]) : 0;
	} else {
		say("SWEET RUN: $ %s%s", cmd, background ? " &" : "");
		run(argv, background);
	}
	return -1;
}

int
main(void)
{
	for (int i = 0; i < MAX_JOBS; i++) {
		jobs[i].fd = -1;
	}
	signal(SIGPIPE, SIG_IGN);
	setenv("PATH", DIR_BOX ":/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec", 1);
	setenv("HOME", DIR_BOX, 1);
	(void)chdir(DIR_BOX);

	say("SWEET RUN: waiting for " DONE_FILE " (up to %d s)", WAIT_SECS);
	struct stat st;
	int waited = 0;
	while (!(stat(DONE_FILE, &st) == 0 && st.st_size > 0)) {
		if (waited++ >= WAIT_SECS) {
			say("SWEET RUN: no SWEETBOX this boot, nothing to run");
			return 0;
		}
		sleep(1);
	}
	FILE *f = fopen(SCRIPT, "r");
	if (!f) {
		say("SWEET RUN: box extracted, no autorun.sh (%s)", strerror(errno));
		return 0;
	}
	if (rename(SCRIPT, SCRIPT_RAN) != 0) {
		say("SWEET RUN: rename autorun.sh: %s", strerror(errno));
	}
	say("SWEET RUN: running autorun.sh");
	char line[2048];
	int lineno = 0, status = -1;
	while (status < 0 && fgets(line, sizeof(line), f)) {
		lineno++;
		line[strcspn(line, "\r\n")] = '\0';
		status = line_run(line, lineno);
	}
	fclose(f);
	say("SWEET RUN: autorun.sh done (%d lines), waiting for background jobs", lineno);
	relay(NULL);
	say("SWEET RUN: all jobs finished");
	return status < 0 ? 0 : status;
}
