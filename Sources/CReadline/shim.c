#include "include/CReadline.h"

#include <editline/readline.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static marlo_completion_fn g_completion = NULL;

/// Snapshot of the line being edited, taken once per completion attempt.
///
/// The generator runs many times per attempt (once per candidate) while
/// `rl_line_buffer` stays constant, so copying it once keeps the generator from
/// having to know about libedit's buffer lifetime.
static char *g_line = NULL;

/// libedit asks for matches one at a time; the Swift side decides what they
/// are. strdup because libedit takes ownership of what it is given.
static char *completion_generator(const char *word, int state) {
    if (g_completion == NULL) return NULL;
    const char *match = g_completion(g_line != NULL ? g_line : "", word, state);
    return match != NULL ? strdup(match) : NULL;
}

static char **completion_attempt(const char *word, int start, int end) {
    (void)start;
    (void)end;
    free(g_line);
    g_line = strdup(rl_line_buffer != NULL ? rl_line_buffer : "");

    /* Suppress libedit's filename completion so a slash command completes
       against marlo's own list and never against the filesystem. */
    rl_attempted_completion_over = 1;
    return rl_completion_matches(word, completion_generator);
}

void marlo_readline_setup(marlo_completion_fn fn) {
    g_completion = fn;
    rl_attempted_completion_function = completion_attempt;
}

char *marlo_readline(const char *prompt) {
    return readline(prompt);
}

void marlo_readline_add_history(const char *line) {
    if (line != NULL && line[0] != '\0') {
        add_history(line);
    }
}

char *marlo_readline_plain(void) {
    size_t capacity = 256;
    size_t length = 0;
    char *buffer = malloc(capacity);
    if (buffer == NULL) return NULL;

    int character = 0;
    int sawAny = 0;
    while ((character = fgetc(stdin)) != EOF) {
        sawAny = 1;
        if (character == '\n') break;
        if (length + 2 > capacity) {
            capacity *= 2;
            char *grown = realloc(buffer, capacity);
            if (grown == NULL) {
                free(buffer);
                return NULL;
            }
            buffer = grown;
        }
        buffer[length++] = (char)character;
    }
    buffer[length] = '\0';

    if (!sawAny && length == 0) {
        free(buffer);
        return NULL;
    }
    return buffer;
}
