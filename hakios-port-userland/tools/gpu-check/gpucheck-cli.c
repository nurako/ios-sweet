/*
 * gpucheck-cli: the off-screen half of xiongnemo/ios-gpu-check as a command-line
 * program, for the image this tree builds (no UIKit, no EAGL, no window server).
 *
 * Upstream ios-gpu-check is an application: OpenGLES.framework -> EAGLContext ->
 * libhakios.gl -> OSMesa -> Mesa/freedreno -> hakios.drm -> HakiosGPU. This file
 * keeps the last four links and drops the first three, so it runs wherever
 * gl_test runs, but runs ios-gpu-check's *sequence* (a fresh context per test, a
 * named line before each test, PASS/FAIL, a watchdog) instead of one triangle.
 *
 * The value is attribution, not coverage: every line is printed before the call
 * that can hang, so the last "running" line names the GL operation our driver
 * stopped on. Each test is the upstream test of the same id, reduced to what it
 * asserts. Nothing here writes to the panel or to an IOSurface.
 *
 *   gpucheck-cli            all off-screen tests
 *   gpucheck-cli LIST       only those ids (prefix match)
 *
 * Build: tools/gpu-check/build-gpucheck-cli.sh (needs out/libOSMesa.8.dylib).
 */
#include <mach/mach_time.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* GL/osmesa.h and GLES2/gl2.h of Mesa, as far as they are used here */
typedef struct osmesa_context *OSMesaContext;
extern OSMesaContext OSMesaCreateContextAttribs(const int *attributes, OSMesaContext share);
extern unsigned char OSMesaMakeCurrent(OSMesaContext context, void *buffer, unsigned type, int width, int height);
extern void OSMesaDestroyContext(OSMesaContext context);
extern void (*OSMesaGetProcAddress(const char *name))(void);

extern const unsigned char *glGetString(unsigned name);
extern void glGetIntegerv(unsigned name, int *value);
extern unsigned glGetError(void);
extern void glFinish(void);
extern void glFlush(void);
extern void glReadPixels(int x, int y, int width, int height, unsigned format, unsigned type, void *pixels);
extern void glGenTextures(int n, unsigned *names);
extern void glBindTexture(unsigned target, unsigned texture);
extern void glTexImage2D(unsigned target, int level, int internal, int width, int height, int border, unsigned format,
    unsigned type, const void *pixels);
extern void glTexParameteri(unsigned target, unsigned name, int value);
extern void glGenFramebuffers(int n, unsigned *names);
extern void glBindFramebuffer(unsigned target, unsigned framebuffer);
extern void glGenRenderbuffers(int n, unsigned *names);
extern void glBindRenderbuffer(unsigned target, unsigned renderbuffer);
extern void glRenderbufferStorage(unsigned target, unsigned format, int width, int height);
extern void glFramebufferRenderbuffer(unsigned target, unsigned attachment, unsigned renderbuffertarget,
    unsigned renderbuffer);
extern void glFramebufferTexture2D(unsigned target, unsigned attachment, unsigned textarget, unsigned texture, int level);
extern unsigned glCheckFramebufferStatus(unsigned target);
extern void glViewport(int x, int y, int width, int height);
extern void glClearColor(float red, float green, float blue, float alpha);
extern void glClear(unsigned mask);
extern unsigned glCreateShader(unsigned type);
extern void glShaderSource(unsigned shader, int count, const char *const *strings, const int *lengths);
extern void glCompileShader(unsigned shader);
extern void glGetShaderiv(unsigned shader, unsigned name, int *value);
extern unsigned glCreateProgram(void);
extern void glAttachShader(unsigned program, unsigned shader);
extern void glBindAttribLocation(unsigned program, unsigned index, const char *name);
extern void glLinkProgram(unsigned program);
extern void glGetProgramiv(unsigned program, unsigned name, int *value);
extern void glUseProgram(unsigned program);
extern void glVertexAttribPointer(unsigned index, int size, unsigned type, unsigned char normalized, int stride,
    const void *pointer);
extern void glEnableVertexAttribArray(unsigned index);
extern void glDrawArrays(unsigned mode, int first, int count);
extern void glGenBuffers(int n, unsigned *names);
extern void glBindBuffer(unsigned target, unsigned buffer);
extern void glBufferData(unsigned target, long size, const void *data, unsigned usage);

#define OSMESA_RGBA                  0x1908
#define OSMESA_FORMAT                0x22
#define OSMESA_DEPTH_BITS            0x30
#define OSMESA_STENCIL_BITS          0x31
#define OSMESA_PROFILE               0x33
#define OSMESA_CONTEXT_MAJOR_VERSION 0x36
#define OSMESA_CONTEXT_MINOR_VERSION 0x37
#define OSMESA_ES_PROFILE            0x38

#define GL_VENDOR                    0x1f00
#define GL_RENDERER                  0x1f01
#define GL_VERSION                   0x1f02
#define GL_EXTENSIONS                0x1f03
#define GL_SHADING_LANGUAGE_VERSION  0x8b8c
#define GL_MAX_TEXTURE_SIZE          0x0d33
#define GL_NUM_EXTENSIONS            0x821d

#define GL_RGBA                      0x1908
#define GL_UNSIGNED_BYTE             0x1401
#define GL_TEXTURE_2D                0x0de1
#define GL_TEXTURE_MIN_FILTER        0x2801
#define GL_TEXTURE_MAG_FILTER        0x2800
#define GL_NEAREST                   0x2600
#define GL_TRIANGLES                 0x0004
#define GL_TRIANGLE_STRIP            0x0005
#define GL_FLOAT                     0x1406
#define GL_COLOR_BUFFER_BIT          0x4000

#define GL_FRAMEBUFFER               0x8d40
#define GL_RENDERBUFFER              0x8d41
#define GL_COLOR_ATTACHMENT0         0x8ce0
#define GL_DEPTH_ATTACHMENT          0x8d00
#define GL_FRAMEBUFFER_COMPLETE      0x8cd5
#define GL_RGBA8_OES                 0x8058
#define GL_DEPTH_COMPONENT16         0x81a5

#define GL_FRAGMENT_SHADER           0x8b30
#define GL_VERTEX_SHADER             0x8b31
#define GL_COMPILE_STATUS            0x8b81
#define GL_LINK_STATUS               0x8b82

#define GL_SYNC_GPU_COMMANDS_COMPLETE 0x9117
#define GL_SYNC_FLUSH_COMMANDS_BIT    0x0001
#define GL_ALREADY_SIGNALED           0x911a
#define GL_CONDITION_SATISFIED        0x911b
#define GL_TIMEOUT_EXPIRED            0x911c
#define GL_WAIT_FAILED                0x911d

#define GL_ARRAY_BUFFER              0x8892
#define GL_STATIC_DRAW               0x88e4
#define GL_MAP_READ_BIT              0x0001
#define GL_MAP_WRITE_BIT             0x0002

/* ES3 entry points Mesa exports but this program does not link by name */
typedef void *(*fence_sync_t)(unsigned condition, unsigned flags);
typedef unsigned (*client_wait_t)(void *sync, unsigned flags, uint64_t timeout);
typedef void (*delete_sync_t)(void *sync);
typedef void *(*map_range_t)(unsigned target, long offset, long length, unsigned access);
typedef unsigned char (*unmap_t)(unsigned target);

#define TEST_TIMEOUT 8
#define WINDOW      16

static char gTest[48];

static void
say(const char *format, ...)
{
	va_list arguments;

	va_start(arguments, format);
	fputs("gpucheck-cli: ", stdout);
	vfprintf(stdout, format, arguments);
	fputc('\n', stdout);
	va_end(arguments);
	fflush(stdout);
}

static void
on_alarm(int signal)
{
	char line[160];
	int n;

	(void)signal;
	n = snprintf(line, sizeof(line), "gpucheck-cli: HUNG in %s (no result in %d s)\n", gTest, TEST_TIMEOUT);
	(void)write(STDOUT_FILENO, line, (size_t)n);
	(void)write(STDERR_FILENO, line, (size_t)n);
	_exit(124);
}

static uint64_t
now_us(void)
{
	static mach_timebase_info_data_t base;

	if (base.denom == 0) {
		mach_timebase_info(&base);
	}
	return mach_absolute_time() * base.numer / base.denom / 1000;
}

/* one context of the version asked for, made current; NULL when there is none */
static OSMesaContext
begin(int version)
{
	static unsigned char window[WINDOW * WINDOW * 4];
	int attributes[] = { OSMESA_FORMAT, OSMESA_RGBA, OSMESA_DEPTH_BITS, 24, OSMESA_STENCIL_BITS, 8, OSMESA_PROFILE,
		OSMESA_ES_PROFILE, OSMESA_CONTEXT_MAJOR_VERSION, version, OSMESA_CONTEXT_MINOR_VERSION, 0, 0 };
	OSMesaContext context = OSMesaCreateContextAttribs(attributes, NULL);

	if (context != NULL && !OSMesaMakeCurrent(context, window, GL_UNSIGNED_BYTE, WINDOW, WINDOW)) {
		OSMesaDestroyContext(context);
		context = NULL;
	}
	return context;
}

static void
end(OSMesaContext context)
{
	while (glGetError() != 0) {
	}
	OSMesaDestroyContext(context);
}

static unsigned
shader(unsigned type, const char *text)
{
	unsigned name = glCreateShader(type);
	int good = 0;

	glShaderSource(name, 1, &text, NULL);
	glCompileShader(name);
	glGetShaderiv(name, GL_COMPILE_STATUS, &good);
	return good ? name : 0;
}

/* the upstream solid-colour program (#version 100, client-side arrays) */
static unsigned
solid_program(void)
{
	static const float corners[] = { -0.8f, -0.6f, 0.8f, -0.6f, 0.0f, 0.7f };
	unsigned vertex, fragment, program;
	int good = 0;

	vertex = shader(GL_VERTEX_SHADER, "attribute vec2 p;\nvoid main() { gl_Position = vec4(p, 0.0, 1.0); }\n");
	fragment = shader(GL_FRAGMENT_SHADER,
	    "precision mediump float;\nvoid main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }\n");
	if (vertex == 0 || fragment == 0) {
		return 0;
	}
	program = glCreateProgram();
	glAttachShader(program, vertex);
	glAttachShader(program, fragment);
	glBindAttribLocation(program, 0, "p");
	glLinkProgram(program);
	glGetProgramiv(program, GL_LINK_STATUS, &good);
	if (!good) {
		return 0;
	}
	glUseProgram(program);
	glVertexAttribPointer(0, 2, GL_FLOAT, 0, 0, corners);
	glEnableVertexAttribArray(0);
	return program;
}

/* an off-screen w x h RGBA8 (+ D16) framebuffer, bound and viewport set; 0 on failure */
static unsigned
make_fbo(int w, int h)
{
	unsigned frame = 0, colour = 0, depth = 0;
	unsigned status;

	glGenFramebuffers(1, &frame);
	glBindFramebuffer(GL_FRAMEBUFFER, frame);
	glGenRenderbuffers(1, &colour);
	glBindRenderbuffer(GL_RENDERBUFFER, colour);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, w, h);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colour);
	glGenRenderbuffers(1, &depth);
	glBindRenderbuffer(GL_RENDERBUFFER, depth);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, w, h);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth);
	status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	glViewport(0, 0, w, h);
	if (status != GL_FRAMEBUFFER_COMPLETE) {
		say("  glCheckFramebufferStatus 0x%04x", status);
		return 0;
	}
	return frame;
}

static int
draw_and_read(int w, int h, const char *id)
{
	OSMesaContext context = begin(2);
	unsigned program, frame = 0;
	uint32_t pixel = 0;
	unsigned char rgba[4] = { 0, 0, 0, 0 };

	if (context == NULL) {
		say("%s FAIL no OpenGL ES 2 context", id);
		return 0;
	}
	program = solid_program();
	if (program != 0) {
		frame = make_fbo(w, h);
	}
	if (program != 0 && frame != 0) {
		glClearColor(0.0f, 0.0f, 1.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		glDrawArrays(GL_TRIANGLES, 0, 3);
		glFinish();
		glReadPixels(w / 2, h / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
		pixel = (uint32_t)rgba[0] << 24 | (uint32_t)rgba[1] << 16 | (uint32_t)rgba[2] << 8 | rgba[3];
	}
	end(context);
	if (pixel == 0xff0000ffu) {
		say("%s PASS %dx%d, the middle is red", id, w, h);
		return 1;
	}
	say("%s FAIL %dx%d, the middle is %08x (want ff0000ff)", id, w, h, pixel);
	return 0;
}

static int
finish_test(void)
{
	OSMesaContext context = begin(2);
	unsigned program, frame = 0;
	uint64_t a, idle, busy;

	if (context == NULL) {
		say("es2.finish FAIL no OpenGL ES 2 context");
		return 0;
	}
	program = solid_program();
	if (program != 0) {
		frame = make_fbo(512, 512);
	}
	if (program == 0 || frame == 0) {
		end(context);
		say("es2.finish FAIL no program or framebuffer");
		return 0;
	}
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glFinish();
	a = now_us();
	glFinish();
	idle = now_us() - a;
	a = now_us();
	for (int i = 0; i < 100; i++) {
		glDrawArrays(GL_TRIANGLES, 0, 3);
	}
	glFinish();
	busy = now_us() - a;
	end(context);
	say("es2.finish %s glFinish idle %llu us; 100 full 512x512 triangles done in %llu us", busy < 1000000 ? "PASS" : "FAIL",
	    (unsigned long long)idle, (unsigned long long)busy);
	return busy < 1000000;
}

static int
fence_test(void)
{
	OSMesaContext context = begin(3);
	fence_sync_t fence_sync;
	client_wait_t client_wait;
	delete_sync_t delete_sync;
	unsigned program, frame = 0, result;
	uint64_t a;
	void *sync;

	if (context == NULL) {
		say("es3.fence FAIL no OpenGL ES 3 context");
		return 0;
	}
	fence_sync = (fence_sync_t)OSMesaGetProcAddress("glFenceSync");
	client_wait = (client_wait_t)OSMesaGetProcAddress("glClientWaitSync");
	delete_sync = (delete_sync_t)OSMesaGetProcAddress("glDeleteSync");
	program = solid_program();
	if (program != 0) {
		frame = make_fbo(256, 256);
	}
	if (fence_sync == NULL || client_wait == NULL || delete_sync == NULL || program == 0 || frame == 0) {
		end(context);
		say("es3.fence FAIL fence functions %p/%p/%p, program %u, framebuffer %u", (void *)fence_sync,
		    (void *)client_wait, (void *)delete_sync, program, frame);
		return 0;
	}
	for (int i = 0; i < 10; i++) {
		glDrawArrays(GL_TRIANGLES, 0, 3);
	}
	sync = fence_sync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
	if (sync == NULL) {
		end(context);
		say("es3.fence FAIL glFenceSync returned NULL (error 0x%04x)", glGetError());
		return 0;
	}
	glFlush();
	a = now_us();
	result = client_wait(sync, 0, 1000000000ull);
	delete_sync(sync);
	end(context);
	say("es3.fence %s glClientWaitSync 0x%04x after %llu us (want signalled within 1 s)",
	    (result == GL_ALREADY_SIGNALED || result == GL_CONDITION_SATISFIED) ? "PASS" : "FAIL", result,
	    (unsigned long long)(now_us() - a));
	return result == GL_ALREADY_SIGNALED || result == GL_CONDITION_SATISFIED;
}

static int
map_test(void)
{
	OSMesaContext context = begin(3);
	map_range_t map_range;
	unmap_t unmap;
	unsigned buffer = 0, errors = 0;
	unsigned char *bytes;
	int good = 0;

	if (context == NULL) {
		say("es3.mapbufferrange FAIL no OpenGL ES 3 context");
		return 0;
	}
	map_range = (map_range_t)OSMesaGetProcAddress("glMapBufferRange");
	unmap = (unmap_t)OSMesaGetProcAddress("glUnmapBuffer");
	if (map_range == NULL || unmap == NULL) {
		end(context);
		say("es3.mapbufferrange FAIL glMapBufferRange %p glUnmapBuffer %p", (void *)map_range, (void *)unmap);
		return 0;
	}
	glGenBuffers(1, &buffer);
	glBindBuffer(GL_ARRAY_BUFFER, buffer);
	glBufferData(GL_ARRAY_BUFFER, 4096, NULL, GL_STATIC_DRAW);
	bytes = map_range(GL_ARRAY_BUFFER, 0, 4096, GL_MAP_WRITE_BIT);
	if (bytes != NULL) {
		for (int i = 0; i < 4096; i++) {
			bytes[i] = (unsigned char)(i * 7);
		}
		unmap(GL_ARRAY_BUFFER);
		bytes = map_range(GL_ARRAY_BUFFER, 0, 4096, GL_MAP_READ_BIT);
		if (bytes != NULL) {
			for (int i = 0; i < 4096; i++) {
				errors += bytes[i] != (unsigned char)(i * 7);
			}
			unmap(GL_ARRAY_BUFFER);
			good = errors == 0;
		}
	}
	end(context);
	say("es3.mapbufferrange %s 4096 bytes written and read back, %u wrong", good ? "PASS" : "FAIL", errors);
	return good;
}

static int
context_test(int version, const char *id)
{
	OSMesaContext context = begin(version);
	const char *renderer, *glversion, *glsl;
	int extensions = -1, size = 0;

	if (context == NULL) {
		say("%s FAIL no OpenGL ES %d context", id, version);
		return 0;
	}
	renderer = (const char *)glGetString(GL_RENDERER);
	glversion = (const char *)glGetString(GL_VERSION);
	glsl = (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION);
	glGetIntegerv(GL_MAX_TEXTURE_SIZE, &size);
	if (version >= 3) {
		glGetIntegerv(GL_NUM_EXTENSIONS, &extensions);
	}
	end(context);
	say("%s %s %s | %s | shaders %s | max texture %d | %d extensions", id,
	    renderer != NULL && strstr(renderer, "softpipe") == NULL ? "PASS" : "FAIL", renderer ? renderer : "(NULL)",
	    glversion ? glversion : "(NULL)", glsl ? glsl : "(NULL)", size, extensions);
	return renderer != NULL && strstr(renderer, "softpipe") == NULL;
}

int
main(int argc, char **argv)
{
	static const struct {
		const char *id;
		int (*run)(void);
	} tests[] = {
		{ "ctx.es2", NULL },
		{ "ctx.es3", NULL },
		{ "es2.fbo.d16", NULL },
		{ "es2.finish", finish_test },
		{ "es3.fence", fence_test },
		{ "es3.mapbufferrange", map_test },
	};
	const char *only = argc > 1 ? argv[1] : NULL;
	int passed = 0, ran = 0;

	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	signal(SIGALRM, on_alarm);
	say("start (watchdog %d s per test; unbuffered)", TEST_TIMEOUT);
	for (unsigned i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
		int good;

		if (only != NULL && strncmp(tests[i].id, only, strlen(only)) != 0) {
			continue;
		}
		snprintf(gTest, sizeof(gTest), "%s", tests[i].id);
		say("%s running", tests[i].id);
		alarm(TEST_TIMEOUT);
		if (strcmp(tests[i].id, "ctx.es2") == 0) {
			good = context_test(2, tests[i].id);
		} else if (strcmp(tests[i].id, "ctx.es3") == 0) {
			good = context_test(3, tests[i].id);
		} else if (tests[i].run == NULL) {
			good = draw_and_read(64, 64, tests[i].id);
		} else {
			good = tests[i].run();
		}
		alarm(0);
		ran++;
		passed += good;
	}
	say("done %d pass, %d fail (%d tests)", passed, ran - passed, ran);
	return ran > 0 && passed == ran ? 0 : 1;
}
